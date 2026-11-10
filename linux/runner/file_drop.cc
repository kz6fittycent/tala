#include "file_drop.h"

// Flutter has no file drops on Linux, so the view is made a GTK drop target.
// Only local files are passed on: a URI with no local path (a web link, a
// remote share) is skipped.

struct _FileDrop {
  FlMethodChannel* channel;
  GtkWidget* widget;
  gboolean hovering;
};

static void send(FileDrop* drop, const gchar* method, FlValue* args) {
  fl_method_channel_invoke_method(drop->channel, method, args, nullptr,
                                  nullptr, nullptr);
}

static void set_hover(FileDrop* drop, gboolean hovering) {
  if (drop->hovering == hovering) return;
  drop->hovering = hovering;
  g_autoptr(FlValue) value = fl_value_new_bool(hovering);
  send(drop, "hover", value);
}

static gboolean drag_motion_cb(GtkWidget* widget, GdkDragContext* context,
                               gint x, gint y, guint time,
                               gpointer user_data) {
  // Text or anything else that isn't a list of files is refused.
  if (gtk_drag_dest_find_target(widget, context, nullptr) == GDK_NONE) {
    gdk_drag_status(context, static_cast<GdkDragAction>(0), time);
    return FALSE;
  }
  set_hover(static_cast<FileDrop*>(user_data), TRUE);
  gdk_drag_status(context, GDK_ACTION_COPY, time);
  return TRUE;
}

static void drag_leave_cb(GtkWidget* widget, GdkDragContext* context,
                          guint time, gpointer user_data) {
  set_hover(static_cast<FileDrop*>(user_data), FALSE);
}

static void drag_data_received_cb(GtkWidget* widget, GdkDragContext* context,
                                  gint x, gint y, GtkSelectionData* data,
                                  guint info, guint time,
                                  gpointer user_data) {
  FileDrop* drop = static_cast<FileDrop*>(user_data);
  set_hover(drop, FALSE);
  g_autoptr(FlValue) paths = fl_value_new_list();
  g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr; uri++) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path != nullptr) fl_value_append_take(paths, fl_value_new_string(path));
  }
  gtk_drag_finish(context, fl_value_get_length(paths) > 0, FALSE, time);
  if (fl_value_get_length(paths) > 0) send(drop, "files", paths);
}

FileDrop* file_drop_new(FlView* view) {
  FileDrop* drop = g_new0(FileDrop, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  drop->channel =
      fl_method_channel_new(messenger, "tala/drop", FL_METHOD_CODEC(codec));
  drop->widget = GTK_WIDGET(view);

  gtk_drag_dest_set(drop->widget, GTK_DEST_DEFAULT_DROP, nullptr, 0,
                    GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(drop->widget);
  g_signal_connect(drop->widget, "drag-motion", G_CALLBACK(drag_motion_cb),
                   drop);
  g_signal_connect(drop->widget, "drag-leave", G_CALLBACK(drag_leave_cb),
                   drop);
  g_signal_connect(drop->widget, "drag-data-received",
                   G_CALLBACK(drag_data_received_cb), drop);
  return drop;
}

void file_drop_free(FileDrop* drop) {
  g_signal_handlers_disconnect_by_data(drop->widget, drop);
  gtk_drag_dest_unset(drop->widget);
  g_clear_object(&drop->channel);
  g_free(drop);
}
