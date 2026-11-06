#include "tray.h"

#include <glib/gstdio.h>
#include <string.h>

// libayatana-appindicator marks its GTK3 API deprecated in favor of a newer
// library that distributions don't ship widely yet.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#include <libayatana-appindicator/app-indicator.h>

// If Dart doesn't answer a quit request in this time, quit anyway.
static const guint kQuitTimeoutSeconds = 5;

struct _Tray {
  GtkApplication* application;
  GtkWindow* window;
  AppIndicator* indicator;
  FlMethodChannel* channel;
  gboolean quitting;
};

static void quit_now(Tray* tray) { g_application_quit(G_APPLICATION(tray->application)); }

static gboolean quit_timeout_cb(gpointer user_data) {
  quit_now(static_cast<Tray*>(user_data));
  return G_SOURCE_REMOVE;
}

static void quit_response_cb(GObject* object, GAsyncResult* result,
                             gpointer user_data) {
  // Whether Dart finished or failed, it's done with its chance to clean up.
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  quit_now(static_cast<Tray*>(user_data));
}

static void show_window(Tray* tray) {
  gtk_widget_show(GTK_WIDGET(tray->window));
  gtk_window_present(tray->window);
}

static void open_activated_cb(GtkMenuItem* item, gpointer user_data) {
  show_window(static_cast<Tray*>(user_data));
}

// Lets Dart hang up a call and close notifications before the process ends.
static void quit_activated_cb(GtkMenuItem* item, gpointer user_data) {
  Tray* tray = static_cast<Tray*>(user_data);
  if (tray->quitting) return;
  tray->quitting = TRUE;
  g_timeout_add_seconds(kQuitTimeoutSeconds, quit_timeout_cb, tray);
  fl_method_channel_invoke_method(tray->channel, "quit", nullptr, nullptr,
                                  quit_response_cb, tray);
}

static gchar* autostart_path() {
  g_autofree gchar* name = g_strconcat(APPLICATION_ID, ".desktop", nullptr);
  return g_build_filename(g_get_user_config_dir(), "autostart", name, nullptr);
}

// Writes or removes the login entry. Returns whether the entry now matches.
static gboolean set_autostart(gboolean enabled) {
  g_autofree gchar* path = autostart_path();
  if (!enabled) {
    return g_unlink(path) == 0 || !g_file_test(path, G_FILE_TEST_EXISTS);
  }
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return FALSE;
  g_autofree gchar* dir = g_path_get_dirname(path);
  if (g_mkdir_with_parents(dir, 0700) != 0) return FALSE;
  // Double quotes keep a path with spaces in one piece; these characters would
  // need escaping inside them, so refuse rather than write a broken entry.
  if (strpbrk(exe, "\"`$\\") != nullptr) return FALSE;
  g_autofree gchar* exec = g_strdup_printf("\"%s\" --background", exe);
  g_autoptr(GKeyFile) file = g_key_file_new();
  const gchar* group = G_KEY_FILE_DESKTOP_GROUP;
  g_key_file_set_string(file, group, "Type", "Application");
  g_key_file_set_string(file, group, "Name", "Tala");
  g_key_file_set_string(file, group, "Exec", exec);
  g_key_file_set_string(file, group, "Terminal", "false");
  return g_key_file_save_to_file(file, path, nullptr);
}

// The dock's count, through the signal docks listen to. A snap has a different
// desktop file name, so this URI has to change there, and it needs the unity7
// plug. A dock can only show this if it's showing Tala's icon.
static void set_badge(Tray* tray, gint64 count) {
  GDBusConnection* bus =
      g_application_get_dbus_connection(G_APPLICATION(tray->application));
  if (bus == nullptr) return;
  GVariantBuilder props;
  g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&props, "{sv}", "count", g_variant_new_int64(count));
  g_variant_builder_add(&props, "{sv}", "count-visible",
                        g_variant_new_boolean(count > 0));
  g_autoptr(GError) error = nullptr;
  if (!g_dbus_connection_emit_signal(
          bus, nullptr, "/io/github/kz6fittycent/tala/launcher",
          "com.canonical.Unity.LauncherEntry", "Update",
          g_variant_new("(sa{sv})", "application://" APPLICATION_ID ".desktop",
                        &props),
          &error)) {
    g_warning("Could not update the dock count: %s", error->message);
  }
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  Tray* tray = static_cast<Tray*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "show") == 0) {
    show_window(tray);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "close") == 0) {
    // The same path as the window's close button.
    gtk_window_close(tray->window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "badge") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
      set_badge(tray, fl_value_get_int(args));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "getAutostart") == 0) {
    g_autofree gchar* path = autostart_path();
    g_autoptr(FlValue) value =
        fl_value_new_bool(g_file_test(path, G_FILE_TEST_EXISTS));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (g_strcmp0(method, "setAutostart") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    gboolean changed = args != nullptr &&
                       fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                       set_autostart(fl_value_get_bool(args));
    g_autoptr(FlValue) value = fl_value_new_bool(changed);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (g_strcmp0(method, "available") == 0) {
    g_autoptr(FlValue) value = fl_value_new_bool(tray_is_available(tray));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

static gchar* icon_path() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return g_strdup("tala");
  g_autofree gchar* dir = g_path_get_dirname(exe);
  return g_build_filename(dir, "data", "flutter_assets", "assets", "icon",
                          "tala-small-64.png", nullptr);
}

Tray* tray_new(GtkApplication* application, GtkWindow* window, FlView* view) {
  Tray* tray = g_new0(Tray, 1);
  tray->application = application;
  tray->window = window;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  tray->channel = fl_method_channel_new(messenger, "tala/tray",
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(tray->channel, method_call_cb, tray,
                                            nullptr);

  GtkWidget* menu = gtk_menu_new();
  GtkWidget* open_item = gtk_menu_item_new_with_label("Open Tala");
  g_signal_connect(open_item, "activate", G_CALLBACK(open_activated_cb), tray);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  GtkWidget* quit_item = gtk_menu_item_new_with_label("Quit Tala");
  g_signal_connect(quit_item, "activate", G_CALLBACK(quit_activated_cb), tray);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_item);
  gtk_widget_show_all(menu);

  g_autofree gchar* icon = icon_path();
  tray->indicator = app_indicator_new("tala", icon,
                                      APP_INDICATOR_CATEGORY_COMMUNICATIONS);
  app_indicator_set_title(tray->indicator, "Tala");
  app_indicator_set_menu(tray->indicator, GTK_MENU(menu));
  // Some tray hosts send a middle click here.
  app_indicator_set_secondary_activate_target(tray->indicator, open_item);
  app_indicator_set_status(tray->indicator, APP_INDICATOR_STATUS_ACTIVE);
  return tray;
}

gboolean tray_is_available(Tray* tray) {
  gboolean connected = FALSE;
  g_object_get(tray->indicator, "connected", &connected, nullptr);
  return connected;
}

void tray_free(Tray* tray) {
  g_clear_object(&tray->indicator);
  g_clear_object(&tray->channel);
  g_free(tray);
}

#pragma GCC diagnostic pop
