// wasm32 rclc "virtual robot" demo: subscribes to geometry_msgs/Twist on
// 'cmd_vel' -- the same topic both the keyboard (teleop_rclc.c) and
// phone-tilt (imu_rclc.c) demos publish on -- and dead-reckons a simple
// unicycle-model pose (x, y, theta) from it, so there's something to look
// at without needing real robot hardware.
//
// Same shared-memory architecture as the publisher demos, just the
// opposite direction: this worker thread integrates pose and writes it
// into wasm linear memory; index_robot_view.html (the real main thread,
// since canvas rendering needs DOM access the worker doesn't have) polls
// it on every animation frame to redraw a small robot icon.
#include <stdio.h>
#include <math.h>

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
#include <geometry_msgs/msg/twist.h>

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

rcl_subscription_t subscription;
geometry_msgs__msg__Twist cmd_vel_msg;

// Last-received velocity, applied continuously by the integration timer
// below rather than only on message receipt -- keeps the visualized
// motion smooth even if Twist messages arrive irregularly, same as a
// real motion-integration loop would.
static double current_linear_x = 0.0;
static double current_angular_z = 0.0;

// Read by index_robot_view.html every animation frame (main thread);
// written by the integration timer callback below (worker thread).
typedef struct {
  double x;
  double y;
  double theta;
} robot_pose_t;

static robot_pose_t robot_pose = {0.0, 0.0, 0.0};

EMSCRIPTEN_KEEPALIVE
robot_pose_t * robot_view_get_pose_ptr(void)
{
  return &robot_pose;
}

void cmd_vel_callback(const void * msgin)
{
  const geometry_msgs__msg__Twist * twist = (const geometry_msgs__msg__Twist *)msgin;
  current_linear_x = twist->linear.x;
  current_angular_z = twist->angular.z;
}

#define INTEGRATION_PERIOD_S 0.05 // 20 Hz

void integration_timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  // Simple unicycle model: integrate heading first, then position along
  // the new heading -- standard first-order dead reckoning, plenty
  // accurate for a demo running at 20 Hz.
  robot_pose.theta += current_angular_z * INTEGRATION_PERIOD_S;
  robot_pose.x += current_linear_x * cos(robot_pose.theta) * INTEGRATION_PERIOD_S;
  robot_pose.y += current_linear_x * sin(robot_pose.theta) * INTEGRATION_PERIOD_S;
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
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_robot_view_rclc", "", &support));

  subscription = rcl_get_zero_initialized_subscription();
  RCCHECK(rclc_subscription_init_default(
    &subscription, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(geometry_msgs, msg, Twist),
    "cmd_vel"));

  rcl_timer_t integration_timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &integration_timer, &support, RCL_MS_TO_NS((int)(INTEGRATION_PERIOD_S * 1000)),
    integration_timer_callback));

  // One subscription + one timer -> handle count 2.
  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 2, &allocator));
  RCCHECK(rclc_executor_add_subscription(
    &executor, &subscription, &cmd_vel_msg, &cmd_vel_callback, ON_NEW_DATA));
  RCCHECK(rclc_executor_add_timer(&executor, &integration_timer));

  geometry_msgs__msg__Twist__init(&cmd_vel_msg);

  printf("wasm32 rclc robot_view demo starting, subscribing to Twist on 'cmd_vel' via rmw_zenoh_pico\n");
  printf("Drive it from the teleop or IMU demo pages.\n");

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(20));
  }

  RCCHECK(rcl_subscription_fini(&subscription, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
