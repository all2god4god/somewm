package compositor

import bk "../backend"
import out "../outputs"
import st "../seat"
import vm "../lua_runtime"
import wl "../wayland"
import "base:runtime"

Touch :: struct {
	server: ^Server,
	device: ^bk.Device,
	id:     u64,
	destroy, down, up, motion, cancel, frame: wl.Listener,
}

// Layout origin of the surface a point went down on. Motion stays relative to
// it even after the finger leaves the surface.
Touch_Point :: struct {
	x, y:   f64,
	device: u64,
}

touch_added :: proc(s: ^Server, device: ^bk.Device) {
	handle := bk.touch_of(device)
	t := new(Touch)
	t.server, t.device = s, device
	s.next_touch += 1
	t.id = s.next_touch
	append(&s.touches, t)
	wl.listen(&device.events.destroy, &t.destroy, touch_destroy)
	wl.listen(&handle.events.down, &t.down, touch_down)
	wl.listen(&handle.events.up, &t.up, touch_up)
	wl.listen(&handle.events.motion, &t.motion, touch_motion)
	wl.listen(&handle.events.cancel, &t.cancel, touch_cancel)
	wl.listen(&handle.events.frame, &t.frame, touch_frame)
	update_capabilities(s)
}

touch_destroy :: proc(listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	t := wl.owner(listener, Touch, "destroy")
	s := t.server
	for l in ([]^wl.Listener{&t.destroy, &t.down, &t.up, &t.motion, &t.cancel, &t.frame}) {wl.unlisten(l)}
	for other, i in s.touches {
		if other == t {
			ordered_remove(&s.touches, i)
			break
		}
	}
	// A removed device never sends up, so its clients would hold the points forever.
	held := make([dynamic]i32, context.temp_allocator)
	for id, point in s.touch_points {if point.device == t.id {append(&held, id)}}
	for id in held {
		delete_key(&s.touch_points, id)
		if s.seat != nil {st.touch_notify_cancel(s.seat, id)}
	}
	if s.seat != nil {update_capabilities(s)}
	free(t)
}

find_touch :: proc(s: ^Server, id: u64) -> ^Touch {
	for t in s.touches {if t.id == id {return t}}
	return nil
}

touch_position :: proc(s: ^Server, touch: ^bk.Touch, x, y: f64) -> (f64, f64) {
	output: ^out.Output
	if touch.output_name != "" {
		for o in s.outputs {
			if string(o.handle.name) == touch.output_name {
				output = o.handle
				break
			}
		}
	}
	box := out.layout_box(s.layout, output)
	return f64(box.x) + x * f64(box.width), f64(box.y) + y * f64(box.height)
}

touch_queue :: proc(t: ^Touch, native: vm.Native_Input, data: rawptr) {
	s := t.server
	idle_activity(s)
	event := (^bk.Touch_Event)(data)
	e := vm.Event {
		native       = native,
		time         = event.time_msec,
		touch_device = t.id,
		touch_id     = event.id,
	}
	if native == .TouchDown || native == .TouchMotion {e.px, e.py = touch_position(s, event.touch, event.x, event.y)}
	// Lua sees presses and releases; motion and frames only reach clients.
	if native == .TouchDown || native == .TouchUp {
		e.name = "touch"
		e.pressed = native == .TouchDown
	}
	queue_event(s, e)
}

touch_down :: proc(listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	touch_queue(wl.owner(listener, Touch, "down"), .TouchDown, data)
}
touch_up :: proc(listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	touch_queue(wl.owner(listener, Touch, "up"), .TouchUp, data)
}
touch_motion :: proc(listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	touch_queue(wl.owner(listener, Touch, "motion"), .TouchMotion, data)
}
touch_cancel :: proc(listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	touch_queue(wl.owner(listener, Touch, "cancel"), .TouchCancel, data)
}
touch_frame :: proc(listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	t := wl.owner(listener, Touch, "frame")
	queue_event(t.server, vm.Event{native = .TouchFrame, touch_device = t.id})
}

// Drops every point clients hold, for claims and locks that take input away.
touch_cancel_all :: proc(s: ^Server) {
	clear(&s.touch_points)
	st.touch_cancel_all(s.seat)
}

// The queued payload keeps ownership of its strings, so facts go on a copy.
touch_dispatch :: proc(s: ^Server, event: ^vm.Event) {
	e := event^
	#partial switch e.native {
	case .TouchDown:
		if find_touch(s, e.touch_device) == nil {return}
		blocked := s.pointer_grabbed || e.routing_epoch != s.pointer_epoch
		position_fact(s, &e)
		surface, _, sx, sy := hit_test(s, e.px, e.py)
		if !blocked && popup_press(s, surface) {return}
		e.blocked, e.claimed = blocked, blocked
		epoch := s.pointer_epoch
		vm.deliver(&s.lua, &e)
		if s.shutting_down || blocked || s.pointer_grabbed || epoch != s.pointer_epoch {return}
		// Lua may have raised or moved a view while handling the press.
		surface, _, sx, sy = hit_test(s, e.px, e.py)
		if surface == nil || !popup_pointer_allowed(s, surface) {return}
		s.touch_points[e.touch_id] = {e.px - sx, e.py - sy, e.touch_device}
		st.touch_notify_down(s.seat, surface, e.time, e.touch_id, sx, sy)
		// A protocol grab can defer an already selected target until dismissal.
		if !s.keyboard_grabbed && runtime_focused(s) != s.requested_focus {runtime_focus(s, s.requested_focus)}
	case .TouchMotion:
		if point, ok := s.touch_points[e.touch_id]; ok {
			st.touch_notify_motion(s.seat, e.time, e.touch_id, e.px - point.x, e.py - point.y)
		}
	case .TouchUp:
		_, held := s.touch_points[e.touch_id]
		position_fact(s, &e)
		e.blocked, e.claimed = s.pointer_grabbed, s.pointer_grabbed
		vm.deliver(&s.lua, &e)
		if s.shutting_down || !held {return}
		delete_key(&s.touch_points, e.touch_id)
		st.touch_notify_up(s.seat, e.time, e.touch_id)
	case .TouchCancel:
		if _, ok := s.touch_points[e.touch_id]; ok {
			delete_key(&s.touch_points, e.touch_id)
			st.touch_notify_cancel(s.seat, e.touch_id)
		}
	case .TouchFrame:
		st.touch_notify_frame(s.seat)
	}
}
