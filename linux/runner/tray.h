#ifndef RUNNER_TRAY_H_
#define RUNNER_TRAY_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _Tray Tray;

// Adds the tray icon and its menu, and the "tala/tray" channel to Dart.
Tray* tray_new(GtkApplication* application, GtkWindow* window, FlView* view);

// True only while a tray host is showing the icon. Hiding the window without
// one would leave the user no way back to it.
gboolean tray_is_available(Tray* tray);

void tray_free(Tray* tray);

G_END_DECLS

#endif  // RUNNER_TRAY_H_
