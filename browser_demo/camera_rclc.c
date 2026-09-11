// wasm32 rclc camera demo: the browser's webcam (or, if unavailable, a
// synthetic animated test pattern) drives a sensor_msgs/CompressedImage
// publisher on 'camera/image'.
//
// Same architecture as teleop_rclc.c / gps_rclc.c (see teleop_rclc.c for
// the full rationale): -sPROXY_TO_PTHREAD=1 means main() runs on a
// pthread Web Worker with no DOM/getUserMedia access, so all the canvas
// capture lives in plain JS in index_camera.html (the real main thread),
// which JPEG-encodes each frame (canvas.toBlob('image/jpeg')) and writes
// the compressed bytes directly into wasm linear memory. The worker-side
// timer callback just publishes whatever's currently there, unlike
// teleop/gps there's no "has data yet" flag needed for this one -- the
// test-pattern fallback means there's always *something* real to
// publish, camera permission or not.
//
// Originally published raw sensor_msgs/Image (rgb8, no compression --
// 160x120x3 = 57600 bytes/frame), capped at 2 Hz specifically to avoid
// flooding the websocket with that -- which made the demo feel laggy in
// exactly the way sending uncompressed video always does. JPEG typically
// gets a frame this size under 5 KB, which is why the timer below can run
// an order of magnitude faster than the old raw-frame version while still
// using a fraction of the bandwidth. The buffer is sized for a
// comfortable worst case (MAX_JPEG_BYTES), not the actual per-frame size
// -- see camera_set_frame_length() for how JS reports how much of it is
// actually valid on a given frame.
#include <stdio.h>
#include <string.h>

#include <emscripten.h>

// Not <rmw_zenoh_pico/rmw_zenoh_pico.h> -- its own transitive includes pull
// in rosidl_typesupport_microxrcedds_c's <ucdr/microcdr.h>, which isn't on
// this demo's (deliberately minimal) include path. config.h + options.h is
// all rmw_zenoh_pico_set_unicast()'s declaration actually needs: config.h
// defines RMW_ZENOH_PICO_TRANSPORT_UNICAST, which options.h's declaration
// is guarded on.
#include <rmw_zenoh_pico/config.h>
#include <rmw_zenoh_pico/rmw_zenoh_pico_options.h>

// The zenoh connect address rmw_zenoh_pico compiles in (127.0.0.1:7447) is
// only a *default* -- rmw_zenoh_pico_set_unicast() overrides it at runtime,
// but has to run before rclc_support_init() opens the session. main() is
// linked with -sINVOKE_RUN=0 so JS can write into this buffer (still empty
// means "use the compiled-in default") before calling Module.callMain()
// itself -- see this page's .html file.
#define ZENOH_HOST_MAX 64
#define ZENOH_PORT_MAX 8
static char zenoh_connect_host[ZENOH_HOST_MAX] = "";
static char zenoh_connect_port[ZENOH_PORT_MAX] = "";

EMSCRIPTEN_KEEPALIVE
char * zenoh_get_connect_host_buf(void) { return zenoh_connect_host; }

EMSCRIPTEN_KEEPALIVE
char * zenoh_get_connect_port_buf(void) { return zenoh_connect_port; }
#include <rcl/rcl.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <sensor_msgs/msg/compressed_image.h>
#include <rosidl_runtime_c/string_functions.h>
#include <rosidl_runtime_c/primitives_sequence_functions.h>

// RCL_RET_PUBLISHER_INVALID (300) is what every rcl_publish() call
// returns, over and over, whenever the wasm32 build can't reach a zenoh
// router at ws://127.0.0.1:7447 -- expected while none is running yet,
// not a crash, but "Failed status on line N: 300" reads like one, so
// spell out what it actually means instead of just the raw code.
#define RCCHECK(fn) { rcl_ret_t rc = fn; if (rc != RCL_RET_OK) { \
  if (rc == RCL_RET_PUBLISHER_INVALID) { \
    printf("Line %d: publisher invalid (rc=%d) -- usually means no zenoh router is reachable yet at ws://%s:%s; start one (see the site's setup box).\n", __LINE__, (int)rc, \
      zenoh_connect_host[0] != '\0' ? zenoh_connect_host : "127.0.0.1", \
      zenoh_connect_port[0] != '\0' ? zenoh_connect_port : "7447"); \
  } else { \
    printf("Failed status on line %d: %d\n", __LINE__, (int)rc); \
  } } }

#define IMG_WIDTH 160
#define IMG_HEIGHT 120
// A worst-case comfortable ceiling for a JPEG-compressed 160x120 frame --
// real frames from index_camera.html's canvas.toBlob('image/jpeg', 0.7)
// are typically 2-6 KB. camera_set_frame_length() clamps to this, so an
// unexpectedly busy/noisy frame degrades (truncated data, a visibly bad
// frame) rather than overflowing the buffer.
#define MAX_JPEG_BYTES 32768

rcl_publisher_t publisher;
sensor_msgs__msg__CompressedImage msg;

// index_camera.html JPEG-encodes each frame (main thread, from a
// <video>/getUserMedia frame or the synthetic fallback pattern) and
// writes the compressed bytes here; the worker-side timer callback below
// just publishes whatever's currently there, at its own independent
// rate. camera_set_frame_length() reports how many of the MAX_JPEG_BYTES
// in this buffer are actually valid for the current frame.
EMSCRIPTEN_KEEPALIVE
uint8_t * camera_get_frame_buffer_ptr(void)
{
  return msg.data.data;
}

EMSCRIPTEN_KEEPALIVE
void camera_set_frame_length(size_t len)
{
  msg.data.size = len < MAX_JPEG_BYTES ? len : MAX_JPEG_BYTES;
}

void timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL || msg.data.size == 0) {
    // No real frame from JS yet (camera_set_frame_length() hasn't run) --
    // skip rather than publish an empty CompressedImage.
    return;
  }
  RCCHECK(rcl_publish(&publisher, &msg, NULL));
}

int main(int argc, char const * const * argv)
{
  if (zenoh_connect_host[0] != '\0') {
    rmw_zenoh_pico_set_unicast(
      zenoh_connect_host,
      zenoh_connect_port[0] != '\0' ? zenoh_connect_port : NULL,
      NULL, NULL);
  }

  rcl_allocator_t allocator = rcl_get_default_allocator();
  rclc_support_t support;
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  rcl_node_t node = rcl_get_zero_initialized_node();
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_camera_rclc", "", &support));

  RCCHECK(rclc_publisher_init_default(
    &publisher, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(sensor_msgs, msg, CompressedImage),
    "camera/image"));

  // 10 Hz -- an order of magnitude faster than the old raw-Image version
  // could afford, since a JPEG frame this size is a couple of KB instead
  // of 57.6 KB.
  rcl_timer_t timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &timer, &support, RCL_MS_TO_NS(100), timer_callback));

  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
  RCCHECK(rclc_executor_add_timer(&executor, &timer));

  sensor_msgs__msg__CompressedImage__init(&msg);
  rosidl_runtime_c__String__assign(&msg.header.frame_id, "camera");
  rosidl_runtime_c__String__assign(&msg.format, "jpeg");
  if (!rosidl_runtime_c__uint8__Sequence__init(&msg.data, MAX_JPEG_BYTES)) {
    printf("Failed to allocate image buffer\n");
    return 1;
  }
  // Filled in only once JS starts writing frames -- camera_set_frame_length()
  // starts at 0 (an empty CompressedImage), so nothing publishes until the
  // first real JPEG frame is ready, rather than a bogus all-zero "frame".
  msg.data.size = 0;

  printf("wasm32 rclc camera demo starting, publishing %dx%d JPEG CompressedImage on 'camera/image' via rmw_zenoh_pico\n",
    IMG_WIDTH, IMG_HEIGHT);

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(100));
  }

  RCCHECK(rcl_publisher_fini(&publisher, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
