//
//  HealthKitService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import Foundation
import HealthKit
import Combine
import SwiftUI
import CoreMotion

class HealthKitService: ObservableObject {
    private let healthStore = HKHealthStore()
    private let pedometer = CMPedometer()
    
    @Published var stepCount: Int = 0  // Steps during current walk (from pedometer)
    @Published var totalDailySteps: Int = 0  // Total steps today from HealthKit
    @Published var isAuthorized: Bool = false
    @Published var errorMessage: String?
    @Published var distance: Double = 0 // in meters from pedometer
    
    private var stepQuery: HKObserverQuery?
    private var pedometerStartDate: Date?
    
    // Types we want to read - only step count
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    
    init() {
        checkAuthorization()
    }
    
    var isPedometerAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }
    
    var isMotionAuthorized: Bool {
        CMPedometer.authorizationStatus() == .authorized
    }
    
    var isMotionDenied: Bool {
        let status = CMPedometer.authorizationStatus()
        return status == .denied || status == .restricted
    }
    
    var isMotionNotDetermined: Bool {
        CMPedometer.authorizationStatus() == .notDetermined
    }
    
    /// Request Core Motion authorization by triggering pedometer updates
    /// This uses the same approach as startObservingSteps which successfully shows the prompt
    func requestMotionAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard isPedometerAvailable else {
            completion?(false)
            return
        }
        
        // Use the exact same approach as startObservingSteps - this triggers the permission prompt
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            guard let self = self else { return }
            
            // We got a response (or error) - check authorization status
            DispatchQueue.main.async {
                // Stop the updates since we just wanted to trigger the prompt
                self.pedometer.stopUpdates()
                self.objectWillChange.send()
                
                let granted = CMPedometer.authorizationStatus() == .authorized
                print("📱 Motion authorization result: \(granted), status: \(CMPedometer.authorizationStatus().rawValue)")
                completion?(granted)
            }
        }
    }
    
    var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }
    
    func checkAuthorization() {
        guard isHealthKitAvailable else {
            errorMessage = "HealthKit is not available on this device"
            return
        }
        
        // For read-only permissions, we need to try reading data to check access
        // Query today's steps - if we get data (or no error), we have access
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)
        
        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, error in
            DispatchQueue.main.async {
                // If we get a result without authorization error, we have access
                // HealthKit returns nil result (not an error) when access is revoked
                if error == nil && result != nil {
                    self?.isAuthorized = true
                    // Also refresh total daily steps
                    self?.refreshTotalDailySteps()
                } else {
                    // Check if we previously had authorization
                    let previouslyRequested = UserDefaults.standard.bool(forKey: "healthKitRequested")
                    // If we requested but now can't read, access was revoked
                    self?.isAuthorized = false
                    if previouslyRequested && result == nil {
                        print("📱 HealthKit access appears to have been revoked")
                    }
                }
            }
        }
        healthStore.execute(query)
    }
    
    func requestAuthorization() async -> Bool {
        guard isHealthKitAvailable else {
            errorMessage = "HealthKit is not available on this device"
            return false
        }
        
        let typesToRead: Set<HKObjectType> = [stepType]
        
        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            await MainActor.run {
                self.isAuthorized = true
                // Save that we've requested authorization
                UserDefaults.standard.set(true, forKey: "healthKitRequested")
                // Fetch total daily steps now that we have access
                self.refreshTotalDailySteps()
            }
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = "Authorization failed: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    func startStepCounting(from startDate: Date) {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: nil,
            options: .strictStartDate
        )
        
        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
                return
            }
            
            guard let sum = result?.sumQuantity() else {
                return
            }
            
            let steps = Int(sum.doubleValue(for: HKUnit.count()))
            DispatchQueue.main.async {
                self.stepCount = steps
            }
        }
        
        healthStore.execute(query)
    }
    
    func startObservingSteps(from startDate: Date) {
        stopObserving()
        pedometerStartDate = startDate
        
        // Use CMPedometer for real-time step counting (much more responsive)
        if isPedometerAvailable {
            pedometer.startUpdates(from: startDate) { [weak self] data, error in
                guard let data = data, error == nil else { return }
                
                DispatchQueue.main.async {
                    self?.stepCount = data.numberOfSteps.intValue
                    if let dist = data.distance {
                        self?.distance = dist.doubleValue
                    }
                }
            }
        }
        
        // Also use HealthKit as fallback
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: nil,
            options: .strictStartDate
        )
        
        stepQuery = HKObserverQuery(
            sampleType: stepType,
            predicate: predicate
        ) { [weak self] _, completionHandler, error in
            if error != nil {
                completionHandler()
                return
            }
            
            self?.fetchCurrentSteps(from: startDate)
            completionHandler()
        }
        
        if let query = stepQuery {
            healthStore.execute(query)
        }
        
        // Initial fetch
        fetchCurrentSteps(from: startDate)
    }
    
    private func fetchCurrentSteps(from startDate: Date) {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: Date(),
            options: .strictStartDate
        )
        
        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, _ in
            guard let sum = result?.sumQuantity() else { return }
            
            let steps = Int(sum.doubleValue(for: HKUnit.count()))
            DispatchQueue.main.async {
                self?.stepCount = steps
            }
        }
        
        healthStore.execute(query)
    }
    
    func stopObserving() {
        // Stop pedometer
        pedometer.stopUpdates()
        pedometerStartDate = nil
        
        // Stop HealthKit queries
        if let query = stepQuery {
            healthStore.stop(query)
            stepQuery = nil
        }
        
        // Reset counts
        stepCount = 0
        distance = 0
    }
    
    func getTodaysSteps() async -> Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: Date(),
            options: .strictStartDate
        )
        
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                guard let sum = result?.sumQuantity() else {
                    continuation.resume(returning: 0)
                    return
                }
                
                let steps = Int(sum.doubleValue(for: HKUnit.count()))
                continuation.resume(returning: steps)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Fetch and update total daily steps from HealthKit
    func refreshTotalDailySteps() {
        guard isAuthorized else { return }
        
        Task {
            let steps = await getTodaysSteps()
            await MainActor.run {
                self.totalDailySteps = steps
            }
        }
    }
}


