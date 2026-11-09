package seat

import sf "../surfaces"
import wl "../wayland"
import p "../protocols"

// A point keeps the surface it went down on until up or cancel; motion
// outside that surface still reports to it.
Touch_State :: struct {
	points: [dynamic]^Touch_Point,
	pending: [dynamic]^Client, // Clients owed a frame.
}
Touch_Point :: struct {
	seat: ^Seat,
	id: i32,
	surface: ^sf.Surface,
	client: ^Client,
	destroy: wl.Listener,
}
touch_client_of :: proc(r: ^wl.Resource) -> ^Client { return cast(^Client)r.data if r != nil && r.interface == &p.wl_touch else nil }
touch_bind :: proc(c: ^Client, version: i32, id: u32) {
	r := wl.resource_create_typed(c.client, &p.wl_touch, version, id, c, touch_request, touch_destroy)
	if r == nil { return }
	if c.seat.capabilities&4 == 0 { r.data = nil; return }
	append(&c.touches, r)
}
touch_destroy :: proc(r: ^wl.Resource) { if c := touch_client_of(r); c != nil { remove_resource(&c.touches, r) } }
touch_request :: proc(r: ^wl.Resource, request: p.Wl_Touch_Request, args: []wl.Argument) { wl.resource_destroy(r) }
touch_point :: proc(s: ^Seat, id: i32) -> (^Touch_Point, int) {
	for point, i in s.touch_state.points { if point.id == id { return point, i } }
	return nil, -1
}
touch_point_remove :: proc(s: ^Seat, i: int) {
	point := s.touch_state.points[i]
	wl.unlisten(&point.destroy)
	ordered_remove(&s.touch_state.points, i)
	free(point)
}
touch_pending :: proc(s: ^Seat, c: ^Client) {
	for other in s.touch_state.pending { if other == c { return } }
	append(&s.touch_state.pending, c)
}
touch_surface_gone :: proc(listener: ^wl.Listener, data: rawptr) {
	point := wl.owner(listener, Touch_Point, "destroy")
	s := point.seat
	context = s.display.loop.ctx
	// The client destroyed the surface itself, so it needs no cancel.
	if _, i := touch_point(s, point.id); i >= 0 { touch_point_remove(s, i) }
}
// Points outlive their client; later events for them are dropped.
touch_client_gone :: proc(s: ^Seat, c: ^Client) {
	for point in s.touch_state.points { if point.client == c { point.client = nil } }
	for other, i in s.touch_state.pending { if other == c { ordered_remove(&s.touch_state.pending, i); break } }
}
touch_notify_down :: proc(s: ^Seat, surface: ^sf.Surface, time: u32, id: i32, sx, sy: f64) -> u32 {
	if surface == nil { return 0 }
	if _, i := touch_point(s, id); i >= 0 { touch_point_remove(s, i) }
	point := new(Touch_Point)
	point.seat, point.id, point.surface = s, id, surface
	point.client = client_for(s, surface_resource(surface).client)
	surface_watch(surface, &point.destroy, touch_surface_gone)
	append(&s.touch_state.points, point)
	c := point.client
	if c == nil || len(c.touches) == 0 { return 0 }
	serial := next_serial(c)
	for r in c.touches { wl.post(r, u32(p.Wl_Touch_Event.down), wl.Uint(serial), wl.Uint(time), wl.Object(surface_resource(surface)), wl.Int(id), fixed(sx), fixed(sy)) }
	touch_pending(s, c)
	return serial
}
touch_notify_motion :: proc(s: ^Seat, time: u32, id: i32, sx, sy: f64) {
	point, _ := touch_point(s, id)
	if point == nil || point.client == nil { return }
	for r in point.client.touches { wl.post(r, u32(p.Wl_Touch_Event.motion), wl.Uint(time), wl.Int(id), fixed(sx), fixed(sy)) }
	touch_pending(s, point.client)
}
touch_notify_up :: proc(s: ^Seat, time: u32, id: i32) -> u32 {
	point, i := touch_point(s, id)
	if point == nil { return 0 }
	serial: u32
	if c := point.client; c != nil && len(c.touches) > 0 {
		serial = next_serial(c)
		for r in c.touches { wl.post(r, u32(p.Wl_Touch_Event.up), wl.Uint(serial), wl.Uint(time), wl.Int(id)) }
		touch_pending(s, c)
	}
	touch_point_remove(s, i)
	return serial
}
touch_notify_frame :: proc(s: ^Seat) {
	for c in s.touch_state.pending { for r in c.touches { wl.post(r, u32(p.Wl_Touch_Event.frame)) } }
	clear(&s.touch_state.pending)
}
// wl_touch.cancel ends every point the client holds, not only the one cancelled here.
touch_notify_cancel :: proc(s: ^Seat, id: i32) {
	point, i := touch_point(s, id)
	if point == nil { return }
	if point.client == nil { touch_point_remove(s, i); return }
	touch_cancel_client(s, point.client)
}
touch_cancel_client :: proc(s: ^Seat, c: ^Client) {
	for i := len(s.touch_state.points)-1; i >= 0; i -= 1 { if s.touch_state.points[i].client == c { touch_point_remove(s, i) } }
	if c == nil { return }
	for r in c.touches { wl.post(r, u32(p.Wl_Touch_Event.cancel)) }
	for other, i in s.touch_state.pending { if other == c { ordered_remove(&s.touch_state.pending, i); break } }
}
touch_cancel_all :: proc(s: ^Seat) {
	for len(s.touch_state.points) > 0 { touch_cancel_client(s, s.touch_state.points[0].client) }
}
