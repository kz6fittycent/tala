#ifndef RUNNER_FATAL_SIGNAL_H_
#define RUNNER_FATAL_SIGNAL_H_

// Records a crash in native code (libwebrtc, a GL driver) as a line in
// <config>/tala/fatal.log, which lib/src/report.dart offers to report next time.
void fatal_signal_install();

#endif  // RUNNER_FATAL_SIGNAL_H_
