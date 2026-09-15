import ctypes
import rclpy
from rclpy.node import Node
from rclpy.signals import SignalHandlerOptions
from rclpy.event_handler import PublisherEventCallbacks
from std_msgs.msg import String

# Runtime-configurable zenoh connect address: rmw_zenoh_pico's compiled-in
# default (127.0.0.1:7447) is only a default, overridden here via
# rmw_zenoh_pico_set_unicast() -- same mechanism talker_rclc.c uses, and it
# has to run before rclpy.init() opens the session, for the same reason.
# Unlike talker_rclc.c, rclpy_boot.c never links librmw_zenoh_pico.so
# directly (Python's own `import rclpy` chain dlopen()s it lazily instead),
# so this calls it via ctypes -- confirmed live that ctypes.CDLL() and
# Python's own dlopen()-based import share the same loaded instance (its
# static connect-address globals), not a separate copy. index_rclpy.html
# writes the host/port into rclpy_boot.c's own exported buffers (via
# ccall) before Module.callMain() runs this file; left blank, the buffers
# read back empty and this is a no-op.
_boot = ctypes.CDLL(None)
_boot.zenoh_get_connect_host_buf.restype = ctypes.c_char_p
_boot.zenoh_get_connect_port_buf.restype = ctypes.c_char_p
_zenoh_host = _boot.zenoh_get_connect_host_buf()
_zenoh_port = _boot.zenoh_get_connect_port_buf()
if _zenoh_host:
    _rmw = ctypes.CDLL('librmw_zenoh_pico.so')
    _rmw.rmw_zenoh_pico_set_unicast.argtypes = [ctypes.c_char_p] * 4
    _rmw.rmw_zenoh_pico_set_unicast.restype = None
    _rmw.rmw_zenoh_pico_set_unicast(_zenoh_host, _zenoh_port or b'7447', None, None)
    print('talker_rclpy: zenoh connect address overridden to',
          _zenoh_host, _zenoh_port or b'7447', flush=True)

print("talker_rclpy: rclpy.init()", flush=True)
# install_signal_handlers's default (SignalHandlerOptions.ALL) spawns a real
# std::thread to safely trigger shutdown from a signal handler -- unavailable
# in this non-pthreads build (confirmed: "RuntimeError: thread constructor
# failed: Resource temporarily unavailable"). Nothing in this demo relies on
# Ctrl+C-triggered shutdown, so skip it entirely.
rclpy.init(args=[], signal_handler_options=SignalHandlerOptions.NO)
print("talker_rclpy: rclpy.init() done", flush=True)

_state = {'ready': False, 'node': None, 'pub': None, 'count': 0}


def _timer_cb():
    msg = String()
    msg.data = 'hello from rclpy wasm32 #%d' % _state['count']
    _state['pub'].publish(msg)
    print('talker_rclpy: published:', msg.data, flush=True)
    _state['count'] += 1


def _try_init():
    # rmw_zenoh_pico's z_open() kicks off the WebSocket connection but can't
    # block waiting for it to finish -- so the very first Node() call is
    # *expected* to fail here, every time, regardless of how fast the router
    # responds: the WebSocket "open" callback can only run once this
    # synchronous call returns control to the JS event loop, which hasn't
    # happened yet on the first attempt (see talker_rclc.c for the full
    # rationale, and rclpy_boot.c's rclpy_demo_tick() for what drives this
    # retry from JS). Node() is expected to raise on a failed rcl_node_init
    # rather than leave a half-constructed object needing manual cleanup, so
    # a plain retry-from-scratch on the next tick is safe.
    try:
        # start_parameter_services=False: the parameter get/set/list services
        # pull in service_msgs.ServiceEventInfo's service-introspection
        # "_Event" type, which hits the still-unpatched
        # rosidl_typesupport_microxrcedds_cpp codegen gap (see rclpy_boot.c
        # for the microxrcedds_c-only workaround used elsewhere). Not needed
        # for a plain talker.
        node = Node('wasm_rclpy_talker', enable_rosout=False, start_parameter_services=False)
    except Exception as e:
        print('talker_rclpy: Node() not ready yet (%s), retrying' % e, flush=True)
        return False

    # rmw_zenoh_pico's own QoS event support table used to be permanently
    # empty (no gid_cache), which it signaled with the wrong error code --
    # rclpy's create_event_handlers() only silently no-ops the *correct*
    # "unsupported" code, so the real default here used to raise a plain
    # RCLError. Fixed upstream (rmw_zenoh_pico build 34 in
    # ros-rolling-emscripten-zenoh's own patch) -- publisher construction
    # itself no longer needs use_default_callbacks=False.
    #
    # Real QoS event/matching support landed in build 36 (same patch),
    # which surfaced a separate, still-open gap: rclpy's *default*
    # OFFERED_QOS_INCOMPATIBLE callback can fire spuriously here (rmw_take
    # -- level total_count=0, last_policy_kind=INVALID -- confirmed not
    # coming from this RMW's own graph-cache matching logic, which never
    # runs for this topic at all since nothing subscribes to it) due to
    # what looks like a stale entry in rcl's own wait-set event-array
    # plumbing, not this patch's matching code. use_default_callbacks=False
    # here is purely to keep this demo's own log clean of that spurious
    # warning -- see rmw_zenoh_pico build 36's own rationale in
    # ros-rolling-emscripten-zenoh/pkg_additional_info.yaml for the full
    # writeup and root-cause notes.
    pub = node.create_publisher(String, 'chatter_rclpy', 10,
                                 event_callbacks=PublisherEventCallbacks(use_default_callbacks=False))

    node.create_timer(1.0, _timer_cb)

    _state['node'] = node
    _state['pub'] = pub
    _state['ready'] = True
    print('talker_rclpy: ready, publishing on chatter_rclpy', flush=True)
    return True


def tick():
    if not _state['ready']:
        _try_init()
        return
    rclpy.spin_once(_state['node'], timeout_sec=0.1)
