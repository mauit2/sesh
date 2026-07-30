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

    @State private var viewport: Viewport

    init(readings: [SunReading], previewAt: Date,
         selectedId: Binding<UUID?>, centre: CLLocationCoordinate2D,
         focus: CLLocationCoordinate2D? = nil) {
        self.readings = readings
        self.previewAt = previewAt
        self._selectedId = selectedId
        self.centre = centre
        self.focus = focus
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
                .ignoresSafeArea(edges: [.top, .horizontal])
                .onAppear { relight(proxy) }
                .onChange(of: preset) { _, _ in relight(proxy) }
                .onChange(of: focusKey) { _, _ in flyToFocus() }
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
