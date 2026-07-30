// SunMapbox — the Sun mode's map surface.
//
// This is the one screen that renders on Mapbox rather than MapKit, because
// the whole point of the feature is buildings: Mapbox's Standard style draws
// them in 3D and its `lightPreset` re-lights the whole scene, so scrubbing the
// hour slider visibly moves the shadows across the city. MapKit can render 3D
// buildings but exposes no way to light them, and no way to read their heights
// (which is why the horizons come from Mapbox tiles server-side too).
//
// Everything else in the app stays on MapKit. If this look doesn't earn its
// keep, only this file and the mode's map call change — the sun data is
// source-agnostic.

import SwiftUI
import CoreLocation
import MapboxMaps

struct SunMapboxView: View {
    let readings: [SunReading]
    /// The moment being previewed, which drives the scene's lighting.
    let previewAt: Date
    @Binding var selectedId: UUID?
    let centre: CLLocationCoordinate2D
    /// Set by search to fly the camera onto one venue.
    var focus: CLLocationCoordinate2D?
    /// Raised while the user is touching the map, so the tab pager doesn't
    /// steal the horizontal part of a pinch.
    @Binding var pagingLocked: Bool
    /// Bumped by the locate button. Watched instead of the coordinate so
    /// tapping locate twice from the same spot still recentres.
    var locateTick: Int = 0
    /// False while this map is parked off-screen. The view stays alive so
    /// switching back doesn't reload the style; this stops it drawing frames
    /// meanwhile. See MapRenderGate.
    var rendering: Bool = true

    @State private var viewport: Viewport

    init(readings: [SunReading], previewAt: Date,
         selectedId: Binding<UUID?>, centre: CLLocationCoordinate2D,
         focus: CLLocationCoordinate2D? = nil,
         pagingLocked: Binding<Bool> = .constant(false),
         locateTick: Int = 0,
         rendering: Bool = true) {
        self.readings = readings
        self.previewAt = previewAt
        self._selectedId = selectedId
        self.centre = centre
        self.focus = focus
        self._pagingLocked = pagingLocked
        self.locateTick = locateTick
        self.rendering = rendering
        // Pitched in so the extrusions read as buildings, not footprints.
        _viewport = State(initialValue: .camera(center: centre, zoom: 15.2,
                                                bearing: 0, pitch: 55))
    }

    // Kept deliberately thin: inlining the style + annotations blew past the
    // Swift type-checker's budget ("unable to type-check in reasonable time"),
    // the same ceiling SessionView.body runs into. Explicit types, one job per
    // property.
    var body: some View {
        // MapReader so the light preset can be mutated IN PLACE. Passing a new
        // MapStyle on every slider step made Mapbox reload the whole style —
        // which blanked the canvas dark for a beat and read as "it goes dark at
        // 19:00, then sunny again". setStyleImportConfigProperty just re-lights
        // the existing scene.
        MapReader { proxy in
            map
                .mapStyle(baseStyle)
                .ornamentOptions(ornaments)
                // Tell the paged TabView to stand down while a finger is on
                // the map. Mapbox handles pan/pinch with its own UIKit
                // recognisers, and the pager's scroll view was also claiming
                // the horizontal component of a pinch — which slid the whole
                // screen across to Chats mid-zoom.
                //
                // simultaneousGesture, so this OBSERVES without consuming and
                // Mapbox still gets every gesture. An earlier attempt used
                // .gesture(_:including: .subviews), which is a GestureMask that
                // disables the attached gesture entirely and did nothing.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !pagingLocked { pagingLocked = true } }
                        .onEnded { _ in pagingLocked = false }
                )
                .simultaneousGesture(
                    MagnifyGesture(minimumScaleDelta: 0)
                        .onChanged { _ in if !pagingLocked { pagingLocked = true } }
                        .onEnded { _ in pagingLocked = false }
                )
                .onDisappear { pagingLocked = false }
                .ignoresSafeArea(edges: [.top, .horizontal])
                .onAppear { relight(proxy) }
                .onChange(of: preset) { _, _ in relight(proxy) }
                .onChange(of: focusKey) { _, _ in flyToFocus() }
                // Locate: same scale the MapKit maps land on, so switching
                // modes doesn't change how far out you end up.
                .onChange(of: locateTick) { _, _ in
                    guard let f = focus else { return }
                    withViewportAnimation(.easeOut(duration: 0.5)) {
                        viewport = .camera(center: f, zoom: MapLocate.mapboxZoom,
                                           bearing: 0, pitch: 55)
                    }
                }
                // Behind the map, so the gate lands in the same UIKit container
                // and can find the MapView by walking the hierarchy.
                .background(MapRenderGate(rendering: rendering))
        }
    }

    /// Coordinates aren't Equatable, so drive onChange off a stable string.
    private var focusKey: String {
        guard let f = focus else { return "" }
        return "\(f.latitude),\(f.longitude)"
    }

    private func flyToFocus() {
        guard let f = focus else { return }
        withViewportAnimation(.easeOut(duration: 0.9)) {
            viewport = .camera(center: f, zoom: 16.6, bearing: 0, pitch: 55)
        }
    }

    private var preset: String { Self.preset(for: previewAt, at: centre).rawValue }

    private func relight(_ proxy: MapProxy) {
        try? proxy.map?.setStyleImportConfigProperty(
            for: "basemap", config: "lightPreset", value: preset)
    }

    private var map: Map {
        Map(viewport: $viewport) {
            lights
            annotations
        }
    }

    /// REAL cast shadows. Rather than projecting shadow polygons ourselves, we
    /// aim Mapbox's own directional light at the actual sun and let the 3D
    /// buildings cast geometrically correct shadows — which means dragging the
    /// hour slider sweeps the shadows across the city, from the same NOAA sun
    /// position the horizon maths uses. Mapbox's `direction` is (azimuthal,
    /// polar): azimuthal is measured clockwise from true north and is where the
    /// light comes FROM, polar is the angle down from straight overhead.
    @MapContentBuilder
    private var lights: some MapContent {
        let sun = SunPosition.at(previewAt, latitude: centre.latitude,
                                 longitude: centre.longitude)
        let up = max(0.0, sun.altitude)
        // DECLARING LIGHTS TAKES OVER THE SCENE'S BRIGHTNESS. lightPreset still
        // sets sky and palette, but it no longer dims anything — which is why an
        // earlier version sat bright white at 23:45. So brightness has to be
        // driven from the sun's own altitude here: 0 below -6°, 1 above +6°.
        let daylight = min(1.0, max(0.0, (sun.altitude + 6) / 12))
        DirectionalLight(id: "sesh-sun")
            .direction(azimuthal: sun.azimuth, polar: min(90, max(0, 90 - up)))
            .castShadows(true)
            // Long soft shadows at a low sun, crisp ones at midday, none at night.
            .shadowIntensity(0.2 + 0.6 * daylight)
            .intensity(0.12 + 0.73 * daylight)
        AmbientLight(id: "sesh-ambient")
            // Low at night so the city actually goes dark; enough by day to keep
            // shaded faces readable rather than solid black.
            .intensity(0.10 + 0.40 * daylight)
    }

    // ForEvery, not SwiftUI's ForEach — map content has its own result builder.
    @MapContentBuilder
    private var annotations: some MapContent {
        ForEvery(readings) { (r: SunReading) in
            MapViewAnnotation(coordinate: r.venue.coordinate) {
                SunPin(reading: r, selected: selectedId == r.id) {
                    selectedId = (selectedId == r.id) ? nil : r.id
                }
            }
            .allowOverlap(true)
        }
    }

    /// Buildings on, clutter off: this map exists to show shade, so POI and
    /// transit labels are noise. Lighting follows the previewed hour.
    private var baseStyle: MapStyle {
        MapStyle.standard(
            // Real colours, not monochrome. This map exists to show light, and
            // greyscale buildings made sunlit and shaded faces read the same.
            theme: .default,
            showPointOfInterestLabels: false,
            showTransitLabels: false,
            show3dObjects: true
        )
    }

    private var ornaments: OrnamentOptions {
        OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(visibility: .hidden)
        )
    }

    /// Map the previewed time onto Mapbox's four lighting presets, using real
    /// solar altitude at the map centre rather than clock hours — so "dusk"
    /// means the sun is actually low, whatever the season or latitude.
    static func preset(for date: Date, at c: CLLocationCoordinate2D) -> StandardLightPreset {
        let sun = SunPosition.at(date, latitude: c.latitude, longitude: c.longitude)
        // Monotonic by design: night -> dawn -> day -> dusk -> night, with the
        // side of the sky (not the clock) deciding dawn vs dusk. The previous
        // ladder could hand back a BRIGHTER preset later in the evening, which
        // showed up as the scene going dark at 19:00 and sunny again at 20:30.
        let morning = sun.azimuth < 180
        switch sun.altitude {
        case ..<(-2):  return .night
        case ..<12:    return morning ? .dawn : .dusk
        default:       return .day
        }
    }
}

/// Stops a parked Mapbox map from drawing frames, without tearing it down.
///
/// WHY THIS EXISTS. Switching map modes used to destroy the Mapbox view and
/// build a new one on the way back, which means re-reading and re-applying the
/// Standard style every time — the remaining "not instant" part of switching to
/// Sun. Keeping the view alive fixes that, but a hidden MapView is not free:
/// MapView gates its display link purely on window membership and scene
/// activation state (MapView.shouldRunDisplayLink), and never looks at
/// isHidden or alpha, so parked behind another view it keeps ticking.
///
/// MEASURED, on iPhone 17 Pro Max sim, mean %CPU over 15s after a 12s warmup:
///   visible                5.6%   (14.1% peak)
///   parked, gated          0.0%
///   parked, NOT gated      0.9%   (1.1% peak)
/// So the naive keep-it-alive costs about 0.9 points of CPU continuously — a
/// real cost but a modest one, because Mapbox skips redraws when the scene is
/// static; it is nowhere near the 5.6% of a live map. Gating removes it
/// outright. Simulator CPU is only a proxy for device battery — on device a
/// firing display link also keeps the GPU out of its idle states — so treat
/// 0.9 points as the floor of what this saves, not the whole of it.
///
/// `displayState` is the SDK's own answer — documented as controlling "when the
/// map's display link should be active, which directly affects rendering
/// performance and battery usage". Setting it to the empty set leaves no
/// permissible activation state, so shouldRunDisplayLink() always returns false
/// and the CADisplayLink is paused. The map keeps its style, its tiles and its
/// GPU resources, and costs no frames.
///
/// WHY IT HUNTS THROUGH THE VIEW HIERARCHY. SwiftUI's `Map` owns the underlying
/// MapView privately: MapProxy exposes `camera`, `map`, `location` and
/// `viewport`, but not the view itself, so there is no supported way to reach
/// `displayState` from the declarative API. This sits in the map's `background`
/// — same UIKit container — and walks up a few levels looking for it.
struct MapRenderGate: UIViewRepresentable {
    let rendering: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Deferred: on the first pass SwiftUI may not have inserted the MapView
        // yet, and we would find nothing.
        DispatchQueue.main.async {
            guard let map = Self.mapView(near: uiView) else { return }
            let wanted: MapView.DisplayState =
                rendering ? [.foregroundActive, .foregroundInactive] : []
            if map.displayState.rawValue != wanted.rawValue {
                map.displayState = wanted
            }
        }
    }

    /// Nearest MapView reachable by climbing a few levels and searching down.
    /// Bounded on both axes so this can never walk the whole window.
    private static func mapView(near view: UIView) -> MapView? {
        var node: UIView? = view
        var hops = 0
        while let n = node, hops < 6 {
            if let found = search(n, depth: 0) { return found }
            node = n.superview
            hops += 1
        }
        return nil
    }

    private static func search(_ v: UIView, depth: Int) -> MapView? {
        if let m = v as? MapView { return m }
        guard depth < 6 else { return nil }
        for sub in v.subviews {
            if let m = search(sub, depth: depth + 1) { return m }
        }
        return nil
    }
}
