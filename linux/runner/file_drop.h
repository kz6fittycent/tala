#ifndef RUNNER_FILE_DROP_H_
#define RUNNER_FILE_DROP_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _FileDrop FileDrop;

// Lets files be dragged onto the window. Dart hears about them on the
// "tala/drop" channel: "hover" with true or false as a drag comes and goes,
// and "files" with a list of local paths when they're dropped.
FileDrop* file_drop_new(FlView* view);

void file_drop_free(FileDrop* drop);

G_END_DECLS

#endif  // RUNNER_FILE_DROP_H_
