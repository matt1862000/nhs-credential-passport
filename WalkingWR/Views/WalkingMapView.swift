//
//  WalkingMapView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import MapKit

struct WalkingMapView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var route: MKRoute?
    @State private var isLoadingRoute = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    // Clinic location (Longley Centre, Sheffield - S5 7JT)
    let clinicCoordinate = CLLocationCoordinate2D(latitude: 53.4148, longitude: -1.4685)
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Map
                Map(position: $cameraPosition) {
                    // User location
                    UserAnnotation()
                    
                    // Clinic marker
                    Annotation("Clinic", coordinate: clinicCoordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.coralPink)
                                .frame(width: 44, height: 44)
                            Image(systemName: "cross.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Next waypoint marker (if on a route)
                    if let route = viewModel.selectedRoute,
                       let nextWaypoint = nextWaypointCoordinate(for: route) {
                        Annotation("Next Stop", coordinate: nextWaypoint) {
                            ZStack {
                                Circle()
                                    .fill(Color.tealAccent)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    
                    // Discovery markers along the route
                    ForEach(viewModel.selectedRoute?.qrMarkers ?? [], id: \.id) { marker in
                        Annotation(marker.name, coordinate: marker.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(Color.mintGreen)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "mappin")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    
                    // Show route polyline if available
                    if let route = route {
                        MapPolyline(route.polyline)
                            .stroke(Color.tealAccent, lineWidth: 5)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapUserLocationButton()
                    MapScaleView()
                }
                
                // Bottom info card
                VStack {
                    Spacer()
                    
                    WalkingInfoCard(
                        viewModel: viewModel,
                        route: route,
                        isLoadingRoute: isLoadingRoute,
                        onGetDirections: calculateRoute
                    )
                    .padding()
                }
            }
            .navigationTitle("Walking Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                }
            }
            .onAppear {
                // Request location and calculate initial route
                viewModel.locationService.requestPermission()
                if viewModel.selectedRoute != nil {
                    calculateRoute()
                }
            }
        }
    }
    
    // Get the next waypoint coordinate based on current progress
    private func nextWaypointCoordinate(for route: WalkingRoute) -> CLLocationCoordinate2D? {
        guard !route.qrMarkers.isEmpty else { return nil }
        
        // For now, return the first unvisited marker or the clinic if all visited
        let visitedCount = viewModel.userProgress.qrScansCompleted
        if visitedCount < route.qrMarkers.count {
            return route.qrMarkers[visitedCount].coordinate
        }
        return clinicCoordinate // Head back to clinic
    }
    
    // Calculate walking route to next destination
    private func calculateRoute() {
        guard let currentLocation = viewModel.locationService.currentLocation else {
            return
        }
        
        let destination: CLLocationCoordinate2D
        if let selectedRoute = viewModel.selectedRoute,
           let nextWaypoint = nextWaypointCoordinate(for: selectedRoute) {
            destination = nextWaypoint
        } else {
            destination = clinicCoordinate
        }
        
        isLoadingRoute = true
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            isLoadingRoute = false
            if let route = response?.routes.first {
                self.route = route
                
                // Adjust camera to show the route
                let rect = route.polyline.boundingMapRect
                cameraPosition = .rect(rect)
            }
        }
    }
}

// MARK: - Walking Info Card
struct WalkingInfoCard: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    let route: MKRoute?
    let isLoadingRoute: Bool
    let onGetDirections: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 16) {
            // Route info header
            HStack {
                if let selectedRoute = viewModel.selectedRoute {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedRoute.name)
                            .font(.titleMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("\(selectedRoute.distanceMeters)m • \(selectedRoute.durationMinutes) min")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                } else {
                    Text("No route selected")
                        .font(.titleMedium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Distance walked
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(viewModel.locationService.distanceWalked))m")
                        .font(.titleLarge)
                        .fontWeight(.bold)
                        .foregroundColor(.tealAccent)
                    Text("walked")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }
            
            Divider()
            
            // Directions to next point
            if let route = route {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.title)
                        .foregroundColor(.tealAccent)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next waypoint")
                            .font(.caption)
                            .foregroundColor(.primary)
                        Text("\(Int(route.distance))m away")
                            .font(.bodyMedium)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("~\(Int(route.expectedTravelTime / 60)) min walk")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button(action: onGetDirections) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundColor(.tealAccent)
                    }
                }
            } else if isLoadingRoute {
                HStack {
                    ProgressView()
                    Text("Calculating route...")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            } else {
                Button(action: onGetDirections) {
                    HStack {
                        Image(systemName: "location.fill")
                        Text("Get Directions")
                    }
                    .font(.bodyMedium)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.tealAccent)
                    .cornerRadius(25)
                }
            }
            
            // Wait time reminder
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.softAmber)
                Text("Return in \(viewModel.waitTimeInfo.estimatedMinutes) min")
                    .font(.caption)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(20)
        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 10, y: 5)
    }
}

// MARK: - Embedded Walk Map View (for inline display)
struct EmbeddedWalkMapView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var route: MKRoute?
    @Environment(\.colorScheme) var colorScheme
    
    let clinicCoordinate = CLLocationCoordinate2D(latitude: 53.4084, longitude: -1.4350)
    
    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                // Custom user location with heading arrow
                if let location = viewModel.locationService.currentLocation {
                    Annotation("You", coordinate: location.coordinate) {
                        ZStack {
                            // Outer glow
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 60, height: 60)
                            
                            // Direction arrow
                            Image(systemName: "location.north.fill")
                                .font(.title)
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(viewModel.locationService.headingDegrees))
                            
                            // Center dot
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                        }
                    }
                } else {
                    UserAnnotation()
                }
                
                // Clinic marker
                Annotation("Clinic", coordinate: clinicCoordinate) {
                    ZStack {
                        Circle()
                            .fill(Color.coralPink)
                            .frame(width: 36, height: 36)
                        Image(systemName: "cross.circle.fill")
                            .font(.body)
                            .foregroundColor(.white)
                    }
                }
                
                // Next waypoint
                if let selectedRoute = viewModel.selectedRoute,
                   !selectedRoute.qrMarkers.isEmpty {
                    let visitedCount = viewModel.userProgress.qrScansCompleted
                    if visitedCount < selectedRoute.qrMarkers.count {
                        let nextMarker = selectedRoute.qrMarkers[visitedCount]
                        Annotation(nextMarker.name, coordinate: nextMarker.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(Color.tealAccent)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                
                // Route line
                if let route = route {
                    MapPolyline(route.polyline)
                        .stroke(Color.tealAccent, lineWidth: 4)
                }
            }
            .mapStyle(.standard)
            .mapControls {
                MapUserLocationButton()
            }
            
            // Next waypoint info overlay
            VStack {
                Spacer()
                
                if let selectedRoute = viewModel.selectedRoute,
                   !selectedRoute.qrMarkers.isEmpty {
                    let visitedCount = viewModel.userProgress.qrScansCompleted
                    if visitedCount < selectedRoute.qrMarkers.count {
                        let nextMarker = selectedRoute.qrMarkers[visitedCount]
                        
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.title2)
                                .foregroundColor(.tealAccent)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next: \(nextMarker.name)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                if let routeInfo = route {
                                    Text("\(Int(routeInfo.distance))m • ~\(Int(routeInfo.expectedTravelTime / 60)) min")
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                }
                            }
                            
                            Spacer()
                            
                            Button(action: calculateRoute) {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.tealAccent)
                            }
                        }
                        .padding(12)
                        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 5)
                        .padding(12)
                    }
                }
            }
        }
        .onAppear {
            calculateRoute()
        }
    }
    
    private func calculateRoute() {
        guard let currentLocation = viewModel.locationService.currentLocation else { return }
        
        let destination: CLLocationCoordinate2D
        if let selectedRoute = viewModel.selectedRoute,
           !selectedRoute.qrMarkers.isEmpty {
            let visitedCount = viewModel.userProgress.qrScansCompleted
            if visitedCount < selectedRoute.qrMarkers.count {
                destination = selectedRoute.qrMarkers[visitedCount].coordinate
            } else {
                destination = clinicCoordinate
            }
        } else {
            destination = clinicCoordinate
        }
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .walking
        
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first {
                self.route = route
            }
        }
    }
}

// MARK: - Compact Stat Pill
struct CompactStatPill: View {
    let icon: String
    let value: String
    let label: String
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.tealAccent)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.05), radius: 2)
    }
}

// MARK: - Preview
#Preview {
    WalkingMapView(viewModel: WaitingRoomViewModel())
}

