// Tala: screen capture through the xdg-desktop-portal ScreenCast interface and
// PipeWire, done here instead of in libwebrtc's desktop capturer. The prebuilt
// libwebrtc opens one portal session for its source list and another for the
// capture, so people saw two pickers, and it reported neither cancelling nor
// stopping. This opens exactly one session per share and says how it ended.
#ifndef TALA_PORTAL_SCREENCAST_H
#define TALA_PORTAL_SCREENCAST_H

#include <gio/gio.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct pw_thread_loop;
struct pw_context;
struct pw_core;
struct pw_stream;
struct spa_pod;

namespace flutter_webrtc_plugin {

class PortalScreenCast {
 public:
  enum class State { kSharing, kCancelled, kStopped, kFailed };

  struct I420Frame {
    int width = 0;
    int height = 0;
    std::vector<uint8_t> y, u, v;
  };

  // Called on a capture thread, never two at once.
  using FrameCallback = std::function<void(const I420Frame&)>;
  // Called on the main thread, from an idle callback, so it may destroy this.
  // kSharing comes at most once, then at most one of the others.
  using StateCallback = std::function<void(State, const std::string& detail)>;

  PortalScreenCast(FrameCallback on_frame, StateCallback on_state);
  // Ends the share and closes the portal session. Main thread only.
  ~PortalScreenCast();

  PortalScreenCast(const PortalScreenCast&) = delete;
  PortalScreenCast& operator=(const PortalScreenCast&) = delete;

  // Shows the system's picker. Main thread only.
  void Start(bool show_cursor);

 private:
  using Step = void (PortalScreenCast::*)(uint32_t code, GVariant* results);
  struct Listener;

  void Request(const char* method,
               GVariant* params,
               const std::string& token,
               Step next);
  void OnSessionCreated(uint32_t code, GVariant* results);
  void OnSourcesSelected(uint32_t code, GVariant* results);
  void OnStarted(uint32_t code, GVariant* results);
  void OnRemoteOpened(int fd);
  void ConnectPipeWire(int fd);
  uint32_t PortalProperty(const char* name, uint32_t fallback);
  void Emit(State state, const std::string& detail);
  void Ended(uint32_t code, const char* step);

  // PipeWire thread.
  void OnFormat(const ::spa_pod* param);
  void OnStreamState(int state, const char* error);
  void OnProcess();
  void Convert(const uint8_t* src, int stride);
  void Repeat();

  static void OnCallReply(GObject* source, GAsyncResult* res, gpointer data);
  static void OnRemoteReply(GObject* source, GAsyncResult* res, gpointer data);
  static void OnResponse(GDBusConnection*, const char*, const char*,
                         const char*, const char*, GVariant* params,
                         gpointer data);
  static void OnSessionClosed(GDBusConnection*, const char*, const char*,
                              const char*, const char*, GVariant*,
                              gpointer data);

  FrameCallback on_frame_;
  StateCallback on_state_;
  // Cleared on destruction, so callbacks that arrive late do nothing.
  std::shared_ptr<PortalScreenCast*> handle_;
  bool announced_sharing_ = false;
  bool ended_ = false;
  bool show_cursor_ = true;

  GDBusConnection* conn_ = nullptr;
  GCancellable* cancellable_ = nullptr;
  std::string sender_;
  std::string session_;
  guint request_sub_ = 0;
  guint closed_sub_ = 0;
  Step pending_ = nullptr;
  uint32_t node_id_ = 0;

  pw_thread_loop* loop_ = nullptr;
  pw_context* context_ = nullptr;
  pw_core* core_ = nullptr;
  pw_stream* stream_ = nullptr;
  std::unique_ptr<Listener> listener_;
  uint32_t format_ = 0;
  int width_ = 0;
  int height_ = 0;
  std::atomic<bool> streaming_{false};
  // Counted on the PipeWire thread, logged when the share ends.
  std::atomic<int> n_buffers_{0}, n_converted_{0};

  // The last frame, sent again while the screen is still, so someone who
  // starts watching later gets a picture.
  std::mutex frame_mutex_;
  I420Frame frame_;
  std::chrono::steady_clock::time_point last_sent_;
  std::thread repeater_;
  std::mutex repeat_mutex_;
  std::condition_variable repeat_cv_;
  bool stop_repeating_ = false;
};

}  // namespace flutter_webrtc_plugin

#endif  // TALA_PORTAL_SCREENCAST_H
