#include "portal_screencast.h"

#include <gio/gunixfdlist.h>
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>

namespace flutter_webrtc_plugin {

namespace {

constexpr const char* kDesktop = "org.freedesktop.portal.Desktop";
constexpr const char* kDesktopPath = "/org/freedesktop/portal/desktop";
constexpr const char* kScreenCast = "org.freedesktop.portal.ScreenCast";

// Portal answers: 0 chosen, 1 cancelled, 2 anything else.
constexpr uint32_t kChosen = 0;
constexpr uint32_t kCancelled = 1;

std::string NewToken() {
  static std::atomic<unsigned> counter{0};
  return "tala" + std::to_string(getpid()) + "_" + std::to_string(++counter);
}

// Late GLib callbacks hold one of these instead of the object itself.
struct Ref {
  std::shared_ptr<PortalScreenCast*> handle;
};

void FreeRef(gpointer data) {
  delete static_cast<Ref*>(data);
}

void Log(const std::string& line) {
  fprintf(stderr, "tala screencast: %s\n", line.c_str());
}

}  // namespace

struct PortalScreenCast::Listener {
  spa_hook hook{};
  pw_stream_events events{};
};

PortalScreenCast::PortalScreenCast(FrameCallback on_frame,
                                   StateCallback on_state)
    : on_frame_(std::move(on_frame)),
      on_state_(std::move(on_state)),
      handle_(std::make_shared<PortalScreenCast*>(this)) {}

PortalScreenCast::~PortalScreenCast() {
  if (n_buffers_ > 0) {
    // Every picture, and the ones that changed something.
    Log("closing: " + std::to_string(n_buffers_) + " buffers, " +
        std::to_string(n_converted_) + " with a new picture");
  }
  *handle_ = nullptr;
  {
    std::lock_guard<std::mutex> lock(repeat_mutex_);
    stop_repeating_ = true;
  }
  repeat_cv_.notify_all();
  if (repeater_.joinable()) {
    repeater_.join();
  }
  if (loop_) {
    pw_thread_loop_lock(loop_);
    if (stream_) {
      pw_stream_disconnect(stream_);
      pw_stream_destroy(stream_);
    }
    if (core_) {
      pw_core_disconnect(core_);
    }
    pw_thread_loop_unlock(loop_);
    pw_thread_loop_stop(loop_);
    if (context_) {
      pw_context_destroy(context_);
    }
    pw_thread_loop_destroy(loop_);
  }
  if (cancellable_) {
    g_cancellable_cancel(cancellable_);
    g_object_unref(cancellable_);
  }
  if (conn_) {
    if (request_sub_) {
      g_dbus_connection_signal_unsubscribe(conn_, request_sub_);
    }
    if (closed_sub_) {
      g_dbus_connection_signal_unsubscribe(conn_, closed_sub_);
    }
    // Closing the session also closes a picker that's still open.
    if (!session_.empty()) {
      g_dbus_connection_call(conn_, kDesktop, session_.c_str(),
                             "org.freedesktop.portal.Session", "Close",
                             nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, -1,
                             nullptr, nullptr, nullptr);
    }
    g_object_unref(conn_);
  }
}

void PortalScreenCast::Emit(State state, const std::string& detail) {
  struct Event {
    std::shared_ptr<PortalScreenCast*> handle;
    State state;
    std::string detail;
  };
  g_idle_add(
      [](gpointer data) -> gboolean {
        std::unique_ptr<Event> event(static_cast<Event*>(data));
        PortalScreenCast* self = *event->handle;
        if (!self || self->ended_) {
          return G_SOURCE_REMOVE;
        }
        if (event->state == State::kSharing) {
          if (self->announced_sharing_) {
            return G_SOURCE_REMOVE;
          }
          self->announced_sharing_ = true;
        } else {
          self->ended_ = true;
        }
        // May destroy self, so nothing after this.
        self->on_state_(event->state, event->detail);
        return G_SOURCE_REMOVE;
      },
      new Event{handle_, state, detail});
}

void PortalScreenCast::Ended(uint32_t code, const char* step) {
  if (code == kCancelled) {
    Log(std::string(step) + ": cancelled");
    Emit(State::kCancelled, step);
  } else {
    Log(std::string(step) + ": portal answered " + std::to_string(code));
    Emit(State::kFailed, step);
  }
}

uint32_t PortalScreenCast::PortalProperty(const char* name,
                                          uint32_t fallback) {
  GVariant* reply = g_dbus_connection_call_sync(
      conn_, kDesktop, kDesktopPath, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", kScreenCast, name), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  if (!reply) {
    return fallback;
  }
  GVariant* value = nullptr;
  g_variant_get(reply, "(v)", &value);
  uint32_t result = g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)
                        ? g_variant_get_uint32(value)
                        : fallback;
  g_variant_unref(value);
  g_variant_unref(reply);
  return result;
}

void PortalScreenCast::Start(bool show_cursor) {
  show_cursor_ = show_cursor;
  GError* error = nullptr;
  conn_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (!conn_) {
    Log(std::string("no session bus: ") + (error ? error->message : ""));
    g_clear_error(&error);
    Emit(State::kFailed, "no session bus");
    return;
  }
  // Request objects live at a path built from our bus name, so the answer
  // can be listened for before the call is even made.
  sender_ = g_dbus_connection_get_unique_name(conn_) + 1;
  std::replace(sender_.begin(), sender_.end(), '.', '_');
  cancellable_ = g_cancellable_new();

  const std::string token = NewToken();
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "session_handle_token",
                        g_variant_new_string(NewToken().c_str()));
  Request("CreateSession", g_variant_new("(a{sv})", &options), token,
          &PortalScreenCast::OnSessionCreated);
}

void PortalScreenCast::Request(const char* method,
                               GVariant* params,
                               const std::string& token,
                               Step next) {
  const std::string path =
      "/org/freedesktop/portal/desktop/request/" + sender_ + "/" + token;
  pending_ = next;
  Log(std::string("asking: ") + method);
  request_sub_ = g_dbus_connection_signal_subscribe(
      conn_, kDesktop, "org.freedesktop.portal.Request", "Response",
      path.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      &PortalScreenCast::OnResponse, new Ref{handle_}, FreeRef);
  g_dbus_connection_call(conn_, kDesktop, kDesktopPath, kScreenCast, method,
                         params, G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE,
                         -1, cancellable_, &PortalScreenCast::OnCallReply,
                         new Ref{handle_});
}

void PortalScreenCast::OnCallReply(GObject* source,
                                   GAsyncResult* res,
                                   gpointer data) {
  std::unique_ptr<Ref> ref(static_cast<Ref*>(data));
  GError* error = nullptr;
  GVariant* reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);
  PortalScreenCast* self = *ref->handle;
  if (reply) {
    g_variant_unref(reply);
    return;
  }
  if (self) {
    Log(std::string("portal call failed: ") + error->message);
    self->Emit(State::kFailed, "portal call failed");
  }
  g_clear_error(&error);
}

void PortalScreenCast::OnResponse(GDBusConnection*,
                                  const char*,
                                  const char*,
                                  const char*,
                                  const char*,
                                  GVariant* params,
                                  gpointer data) {
  PortalScreenCast* self = *static_cast<Ref*>(data)->handle;
  if (!self || !self->request_sub_) {
    return;
  }
  // Unsubscribing frees `data`, so it's not used after this.
  g_dbus_connection_signal_unsubscribe(self->conn_, self->request_sub_);
  self->request_sub_ = 0;
  uint32_t code = 2;
  GVariant* results = nullptr;
  g_variant_get(params, "(u@a{sv})", &code, &results);
  Log("answer " + std::to_string(code));
  Step step = self->pending_;
  self->pending_ = nullptr;
  if (step) {
    (self->*step)(code, results);
  }
  g_variant_unref(results);
}

void PortalScreenCast::OnSessionCreated(uint32_t code, GVariant* results) {
  if (code != kChosen) {
    return Ended(code, "CreateSession");
  }
  const char* session = nullptr;
  if (!g_variant_lookup(results, "session_handle", "&s", &session)) {
    return Ended(2, "CreateSession");
  }
  session_ = session;
  // The user can end the share from the system, which closes the session.
  closed_sub_ = g_dbus_connection_signal_subscribe(
      conn_, kDesktop, "org.freedesktop.portal.Session", "Closed",
      session_.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      &PortalScreenCast::OnSessionClosed, new Ref{handle_}, FreeRef);

  // Whole screens and single windows, as the system offers them.
  uint32_t types = PortalProperty("AvailableSourceTypes", 1) & 3u;
  if (!types) {
    types = 1;
  }
  const uint32_t cursors = PortalProperty("AvailableCursorModes", 1);
  // 2 draws the pointer into the picture, 1 leaves it out.
  const uint32_t cursor_mode = show_cursor_ && (cursors & 2u) ? 2u : 1u;

  const std::string token = NewToken();
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(types));
  g_variant_builder_add(&options, "{sv}", "multiple",
                        g_variant_new_boolean(FALSE));
  if (cursors & cursor_mode) {
    g_variant_builder_add(&options, "{sv}", "cursor_mode",
                          g_variant_new_uint32(cursor_mode));
  }
  // Ask every time: nothing is remembered between shares.
  g_variant_builder_add(&options, "{sv}", "persist_mode",
                        g_variant_new_uint32(0));
  Request("SelectSources",
          g_variant_new("(oa{sv})", session_.c_str(), &options), token,
          &PortalScreenCast::OnSourcesSelected);
}

void PortalScreenCast::OnSourcesSelected(uint32_t code, GVariant*) {
  if (code != kChosen) {
    return Ended(code, "SelectSources");
  }
  const std::string token = NewToken();
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  Request("Start",
          g_variant_new("(osa{sv})", session_.c_str(), "", &options), token,
          &PortalScreenCast::OnStarted);
}

void PortalScreenCast::OnStarted(uint32_t code, GVariant* results) {
  if (code != kChosen) {
    return Ended(code, "Start");
  }
  GVariant* streams =
      g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
  if (!streams || g_variant_n_children(streams) == 0) {
    if (streams) {
      g_variant_unref(streams);
    }
    return Ended(2, "Start");
  }
  GVariant* properties = nullptr;
  g_variant_get_child(streams, 0, "(u@a{sv})", &node_id_, &properties);
  g_variant_unref(properties);
  g_variant_unref(streams);

  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_dbus_connection_call_with_unix_fd_list(
      conn_, kDesktop, kDesktopPath, kScreenCast, "OpenPipeWireRemote",
      g_variant_new("(oa{sv})", session_.c_str(), &options),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, cancellable_,
      &PortalScreenCast::OnRemoteReply, new Ref{handle_});
}

void PortalScreenCast::OnRemoteReply(GObject* source,
                                     GAsyncResult* res,
                                     gpointer data) {
  std::unique_ptr<Ref> ref(static_cast<Ref*>(data));
  GUnixFDList* fds = nullptr;
  GError* error = nullptr;
  GVariant* reply = g_dbus_connection_call_with_unix_fd_list_finish(
      G_DBUS_CONNECTION(source), &fds, res, &error);
  PortalScreenCast* self = *ref->handle;
  int fd = -1;
  if (reply) {
    gint32 index = -1;
    g_variant_get(reply, "(h)", &index);
    fd = g_unix_fd_list_get(fds, index, &error);
    g_variant_unref(reply);
  }
  if (fds) {
    g_object_unref(fds);
  }
  if (!self) {
    if (fd >= 0) {
      close(fd);
    }
    g_clear_error(&error);
    return;
  }
  if (fd < 0) {
    Log(std::string("no PipeWire connection: ") +
        (error ? error->message : ""));
    g_clear_error(&error);
    self->Emit(State::kFailed, "OpenPipeWireRemote");
    return;
  }
  self->ConnectPipeWire(fd);
}

void PortalScreenCast::OnSessionClosed(GDBusConnection*,
                                       const char*,
                                       const char*,
                                       const char*,
                                       const char*,
                                       GVariant*,
                                       gpointer data) {
  PortalScreenCast* self = *static_cast<Ref*>(data)->handle;
  if (!self) {
    return;
  }
  Log("the session was closed by the system");
  self->session_.clear();
  self->Emit(State::kStopped, "session closed");
}

void PortalScreenCast::ConnectPipeWire(int fd) {
  pw_init(nullptr, nullptr);
  loop_ = pw_thread_loop_new("tala-screencast", nullptr);
  context_ = loop_ ? pw_context_new(pw_thread_loop_get_loop(loop_), nullptr, 0)
                   : nullptr;
  if (!context_ || pw_thread_loop_start(loop_) < 0) {
    close(fd);
    Log("PipeWire didn't start");
    return Emit(State::kFailed, "PipeWire");
  }
  pw_thread_loop_lock(loop_);
  // Takes the descriptor.
  core_ = pw_context_connect_fd(context_, fd, nullptr, 0);
  if (!core_) {
    pw_thread_loop_unlock(loop_);
    Log("PipeWire connection refused");
    return Emit(State::kFailed, "PipeWire");
  }
  stream_ = pw_stream_new(
      core_, "Tala screen share",
      pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY,
                        "Capture", PW_KEY_MEDIA_ROLE, "Screen", nullptr));

  listener_ = std::make_unique<Listener>();
  auto& events = listener_->events;
  events.version = PW_VERSION_STREAM_EVENTS;
  events.state_changed = [](void* data, pw_stream_state, pw_stream_state state,
                            const char* error) {
    static_cast<PortalScreenCast*>(data)->OnStreamState(state, error);
  };
  events.param_changed = [](void* data, uint32_t id, const spa_pod* param) {
    if (id == SPA_PARAM_Format) {
      static_cast<PortalScreenCast*>(data)->OnFormat(param);
    }
  };
  events.process = [](void* data) {
    static_cast<PortalScreenCast*>(data)->OnProcess();
  };
  pw_stream_add_listener(stream_, &listener_->hook, &events, this);

  uint8_t buffer[1024];
  spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  spa_rectangle size_default = SPA_RECTANGLE(1920, 1080);
  spa_rectangle size_min = SPA_RECTANGLE(1, 1);
  spa_rectangle size_max = SPA_RECTANGLE(8192, 8192);
  spa_fraction rate_default = SPA_FRACTION(15, 1);
  spa_fraction rate_min = SPA_FRACTION(0, 1);
  spa_fraction rate_max = SPA_FRACTION(30, 1);
  // Shared memory only, no GPU buffers: offering no modifiers keeps it so.
  const spa_pod* params[1] = {static_cast<const spa_pod*>(
      spa_pod_builder_add_object(
          &builder, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
          SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
          SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
          SPA_FORMAT_VIDEO_format,
          SPA_POD_CHOICE_ENUM_Id(5, SPA_VIDEO_FORMAT_BGRx,
                                 SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_RGBx,
                                 SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBA),
          SPA_FORMAT_VIDEO_size,
          SPA_POD_CHOICE_RANGE_Rectangle(&size_default, &size_min, &size_max),
          SPA_FORMAT_VIDEO_framerate,
          SPA_POD_CHOICE_RANGE_Fraction(&rate_default, &rate_min,
                                        &rate_max)))};
  const int result = pw_stream_connect(
      stream_, PW_DIRECTION_INPUT, node_id_,
      static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
                                   PW_STREAM_FLAG_MAP_BUFFERS),
      params, 1);
  pw_thread_loop_unlock(loop_);
  if (result < 0) {
    Log("PipeWire stream refused");
    return Emit(State::kFailed, "PipeWire");
  }
  repeater_ = std::thread([this] { Repeat(); });
}

void PortalScreenCast::OnFormat(const spa_pod* param) {
  if (!param) {
    return;
  }
  spa_video_info_raw info{};
  if (spa_format_video_raw_parse(param, &info) < 0) {
    return;
  }
  format_ = info.format;
  width_ = static_cast<int>(info.size.width);
  height_ = static_cast<int>(info.size.height);
  Log("format " + std::to_string(width_) + "x" + std::to_string(height_));

  uint8_t buffer[256];
  spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  const spa_pod* params[1] = {static_cast<const spa_pod*>(
      spa_pod_builder_add_object(
          &builder, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
          SPA_PARAM_BUFFERS_dataType,
          SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) |
                                   (1 << SPA_DATA_MemFd))))};
  pw_stream_update_params(stream_, params, 1);
}

void PortalScreenCast::OnStreamState(int state, const char* error) {
  Log(std::string("stream state ") + pw_stream_state_as_string(
      static_cast<pw_stream_state>(state)));
  switch (state) {
    case PW_STREAM_STATE_STREAMING:
      streaming_ = true;
      Emit(State::kSharing, "");
      break;
    case PW_STREAM_STATE_ERROR:
      Log(std::string("stream error: ") + (error ? error : ""));
      Emit(State::kFailed, "stream error");
      break;
    case PW_STREAM_STATE_UNCONNECTED:
      if (streaming_) {
        Emit(State::kStopped, "stream ended");
      }
      break;
    default:
      break;
  }
}

void PortalScreenCast::OnProcess() {
  // Only the newest picture matters.
  pw_buffer* newest = nullptr;
  while (pw_buffer* next = pw_stream_dequeue_buffer(stream_)) {
    if (newest) {
      pw_stream_queue_buffer(stream_, newest);
    }
    newest = next;
  }
  if (!newest) {
    return;
  }
  n_buffers_++;
  spa_buffer* buffer = newest->buffer;
  spa_data& data = buffer->datas[0];
  auto* header = static_cast<spa_meta_header*>(
      spa_buffer_find_meta_data(buffer, SPA_META_Header, sizeof(spa_meta_header)));
  const bool corrupted =
      header && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED);
  // An empty chunk means only the pointer moved, or nothing changed.
  if (!corrupted && data.data && data.chunk && data.chunk->size > 0 &&
      width_ > 0 && height_ > 0) {
    const int stride =
        data.chunk->stride > 0 ? data.chunk->stride : width_ * 4;
    const uint64_t needed =
        static_cast<uint64_t>(data.chunk->offset) +
        static_cast<uint64_t>(stride) * static_cast<uint64_t>(height_);
    if (stride >= width_ * 4 && needed <= data.maxsize) {
      n_converted_++;
      Convert(static_cast<const uint8_t*>(data.data) + data.chunk->offset,
              stride);
    }
  }
  pw_stream_queue_buffer(stream_, newest);
}

void PortalScreenCast::Convert(const uint8_t* src, int stride) {
  // BGRx and BGRA keep blue first in memory; RGBx and RGBA keep red first.
  const bool red_first =
      format_ == SPA_VIDEO_FORMAT_RGBx || format_ == SPA_VIDEO_FORMAT_RGBA;
  const int r_at = red_first ? 0 : 2;
  const int b_at = red_first ? 2 : 0;
  const int w = width_;
  const int h = height_;
  const int cw = (w + 1) / 2;
  const int ch = (h + 1) / 2;

  std::lock_guard<std::mutex> lock(frame_mutex_);
  frame_.width = w;
  frame_.height = h;
  frame_.y.resize(static_cast<size_t>(w) * h);
  frame_.u.resize(static_cast<size_t>(cw) * ch);
  frame_.v.resize(static_cast<size_t>(cw) * ch);
  // BT.601, limited range, as WebRTC's own converters produce.
  for (int row = 0; row < h; row++) {
    const uint8_t* p = src + static_cast<size_t>(row) * stride;
    uint8_t* y = frame_.y.data() + static_cast<size_t>(row) * w;
    for (int col = 0; col < w; col++, p += 4) {
      const int r = p[r_at], g = p[1], b = p[b_at];
      y[col] = static_cast<uint8_t>(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
  }
  for (int row = 0; row < ch; row++) {
    const int y0 = row * 2;
    const int y1 = std::min(y0 + 1, h - 1);
    const uint8_t* top = src + static_cast<size_t>(y0) * stride;
    const uint8_t* bottom = src + static_cast<size_t>(y1) * stride;
    for (int col = 0; col < cw; col++) {
      const int x0 = col * 2 * 4;
      const int x1 = std::min(col * 2 + 1, w - 1) * 4;
      const int r = (top[x0 + r_at] + top[x1 + r_at] + bottom[x0 + r_at] +
                     bottom[x1 + r_at] + 2) >> 2;
      const int g = (top[x0 + 1] + top[x1 + 1] + bottom[x0 + 1] +
                     bottom[x1 + 1] + 2) >> 2;
      const int b = (top[x0 + b_at] + top[x1 + b_at] + bottom[x0 + b_at] +
                     bottom[x1 + b_at] + 2) >> 2;
      const size_t at = static_cast<size_t>(row) * cw + col;
      frame_.u[at] =
          static_cast<uint8_t>(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      frame_.v[at] =
          static_cast<uint8_t>(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
  }
  last_sent_ = std::chrono::steady_clock::now();
  on_frame_(frame_);
}

void PortalScreenCast::Repeat() {
  using namespace std::chrono;
  std::unique_lock<std::mutex> wait_lock(repeat_mutex_);
  while (!repeat_cv_.wait_for(wait_lock, milliseconds(250),
                              [this] { return stop_repeating_; })) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (frame_.width > 0 && steady_clock::now() - last_sent_ > seconds(1)) {
      last_sent_ = steady_clock::now();
      on_frame_(frame_);
    }
  }
}

}  // namespace flutter_webrtc_plugin
