#ifndef RUNNER_KEYRING_H_
#define RUNNER_KEYRING_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _Keyring Keyring;

// Adds the "tala/keyring" channel to Dart, backed by the Secret Service.
Keyring* keyring_new(FlView* view);

void keyring_free(Keyring* keyring);

G_END_DECLS

#endif  // RUNNER_KEYRING_H_
