#include "keyring.h"

#include <libsecret/secret.h>

// Calls are asynchronous because unlocking the keyring can wait on the user,
// and a blocked main thread would freeze the window.

static const SecretSchema kSchema = {
    APPLICATION_ID ".Secret",
    SECRET_SCHEMA_NONE,
    {{"item", SECRET_SCHEMA_ATTRIBUTE_STRING},
     {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}},
};

// Dart tells these two errors apart: "locked" needs the user, while
// "unavailable" can clear up by itself once the login session finishes starting.
static const gchar* kErrorUnavailable = "unavailable";
static const gchar* kErrorLocked = "locked";

struct _Keyring {
  FlMethodChannel* channel;
};

static const gchar* string_arg(FlMethodCall* call, const gchar* name) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, name);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

static void respond(FlMethodCall* call, FlMethodResponse* response) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("Could not answer a keyring call: %s", error->message);
  }
}

static void respond_value(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  respond(call, response);
}

// The message comes from D-Bus and holds no secrets.
static void respond_error(FlMethodCall* call, const gchar* code,
                          const gchar* message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  respond(call, response);
}

// Only reached when the lookup found nothing it could open. An item that exists
// means the user dismissed the unlock prompt, not that they have no account.
static void locked_check_cb(GObject* source, GAsyncResult* result,
                            gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  GList* items = secret_password_search_finish(result, &error);
  if (error != nullptr) {
    respond_error(call, kErrorUnavailable, error->message);
  } else if (items != nullptr) {
    respond_error(call, kErrorLocked, "The keyring is locked");
  } else {
    respond_value(call, nullptr);
  }
  g_list_free_full(items, g_object_unref);
}

static void lookup_cb(GObject* source, GAsyncResult* result,
                      gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  gchar* secret = secret_password_lookup_finish(result, &error);
  if (error != nullptr) {
    respond_error(call, kErrorUnavailable, error->message);
    return;
  }
  if (secret != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(secret);
    respond_value(call, value);
    secret_password_free(secret);
    return;
  }
  // No unlock flag, so this can't prompt a second time.
  secret_password_search(&kSchema, SECRET_SEARCH_NONE, nullptr, locked_check_cb,
                         g_object_ref(call), "item",
                         string_arg(call, "item"), nullptr);
}

static void store_cb(GObject* source, GAsyncResult* result,
                     gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  gboolean stored = secret_password_store_finish(result, &error);
  if (error != nullptr) {
    respond_error(call, kErrorUnavailable, error->message);
  } else if (!stored) {
    respond_error(call, kErrorLocked, "The keyring is locked");
  } else {
    respond_value(call, nullptr);
  }
}

static void clear_cb(GObject* source, GAsyncResult* result,
                     gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  secret_password_clear_finish(result, &error);
  if (error != nullptr) {
    respond_error(call, kErrorUnavailable, error->message);
  } else {
    respond_value(call, nullptr);
  }
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  const gchar* item = string_arg(call, "item");
  if (item == nullptr) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    respond(call, response);
  } else if (g_strcmp0(method, "read") == 0) {
    secret_password_lookup(&kSchema, nullptr, lookup_cb, g_object_ref(call),
                           "item", item, nullptr);
  } else if (g_strcmp0(method, "write") == 0) {
    const gchar* label = string_arg(call, "label");
    const gchar* secret = string_arg(call, "secret");
    if (label == nullptr || secret == nullptr) {
      respond_error(call, "bad_arguments", "write needs a label and a secret");
      return;
    }
    secret_password_store(&kSchema, SECRET_COLLECTION_DEFAULT, label, secret,
                          nullptr, store_cb, g_object_ref(call), "item", item,
                          nullptr);
  } else if (g_strcmp0(method, "delete") == 0) {
    secret_password_clear(&kSchema, nullptr, clear_cb, g_object_ref(call),
                          "item", item, nullptr);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    respond(call, response);
  }
}

Keyring* keyring_new(FlView* view) {
  Keyring* keyring = g_new0(Keyring, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  keyring->channel = fl_method_channel_new(messenger, "tala/keyring",
                                           FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(keyring->channel, method_call_cb,
                                            keyring, nullptr);
  return keyring;
}

void keyring_free(Keyring* keyring) {
  g_clear_object(&keyring->channel);
  g_free(keyring);
}
