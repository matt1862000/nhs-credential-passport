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
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        print("🔍 [MOTION DEBUG] [\(timeString)] 📱 requestMotionAuthorization() CALLED")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Current auth status: \(CMPedometer.authorizationStatus().rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   isPedometerAvailable: \(isPedometerAvailable)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Call stack:")
        Thread.callStackSymbols.prefix(10).enumerated().forEach { index, symbol in
            print("🔍 [MOTION DEBUG] [\(timeString)]     [\(index)] \(symbol)")
        }
        
        guard isPedometerAvailable else {
            print("🔍 [MOTION DEBUG] [\(timeString)]   ❌ Pedometer not available, returning false")
            completion?(false)
            return
        }
        
        print("🔍 [MOTION DEBUG] [\(timeString)]   ⚠️ Starting pedometer.startUpdates() - THIS WILL TRIGGER MOTION PERMISSION DIALOG")
        
        // Use the exact same approach as startObservingSteps - this triggers the permission prompt
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            let callbackTime = Date()
            let callbackTimeString = formatter.string(from: callbackTime)
            print("🔍 [MOTION DEBUG] [\(callbackTimeString)] 📱 Pedometer callback received! data: \(data != nil), error: \(error?.localizedDescription ?? "none")")
            guard let self = self else {
                print("🔍 [MOTION DEBUG] [\(callbackTimeString)]   ❌ Self was nil in callback")
                return
            }
            
            // We got a response (or error) - check authorization status
            DispatchQueue.main.async {
                // Stop the updates since we just wanted to trigger the prompt
                self.pedometer.stopUpdates()
                self.objectWillChange.send()
                
                let granted = CMPedometer.authorizationStatus() == .authorized
                print("🔍 [MOTION DEBUG] [\(callbackTimeString)]   ✅ Motion authorization result: \(granted), status: \(CMPedometer.authorizationStatus().rawValue)")
                completion?(granted)
            }
        }
        print("🔍 [MOTION DEBUG] [\(timeString)]   ✅ pedometer.startUpdates() called, waiting for callback...")
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
        // Query today's steps - if no authorization error, we have access
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)
        
        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, error in
            DispatchQueue.main.async {
                // HealthKit behavior:
                // - error == nil: Query succeeded, we have read access (result may be nil if no data)
                // - error != nil with auth issue: Access denied
                // - result == nil with no error: Access granted but no step data yet
                
                if let error = error {
                    // Check if it's an authorization error
                    let errorString = error.localizedDescription.lowercased()
                    if errorString.contains("authorization") || errorString.contains("denied") || errorString.contains("not determined") {
                        self?.isAuthorized = false
                        print("📱 HealthKit authorization error: \(error.localizedDescription)")
                    } else {
                        // Other error (network, etc.) - assume authorized if we've requested before
                        let previouslyRequested = UserDefaults.standard.bool(forKey: "healthKitRequested")
                        self?.isAuthorized = previouslyRequested
                        print("📱 HealthKit query error (non-auth): \(error.localizedDescription)")
                    }
                } else {
                    // No error means we have read access (even if result is nil/no data)
                    self?.isAuthorized = true
                    print("📱 HealthKit authorized - query succeeded")
                    self?.refreshTotalDailySteps()
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
            
            // Save that we've requested authorization (even if denied)
            UserDefaults.standard.set(true, forKey: "healthKitRequested")
            
            // IMPORTANT: requestAuthorization doesn't tell us if user granted or denied
            // We need to actually check by querying - checkAuthorization does this
            await MainActor.run {
                self.checkAuthorization()
            }
            
            // Return current authorization status
            return await MainActor.run { self.isAuthorized }
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
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        print("🔍 [MOTION DEBUG] [\(timeString)] 🚶 startObservingSteps() CALLED")
        print("🔍 [MOTION DEBUG] [\(timeString)]   startDate: \(startDate)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Current Motion auth status: \(CMPedometer.authorizationStatus().rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   isPedometerAvailable: \(isPedometerAvailable)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Call stack:")
        Thread.callStackSymbols.prefix(10).enumerated().forEach { index, symbol in
            print("🔍 [MOTION DEBUG] [\(timeString)]     [\(index)] \(symbol)")
        }
        
        stopObserving()
        pedometerStartDate = startDate
        
        // Use CMPedometer for real-time step counting (much more responsive)
        if isPedometerAvailable {
            print("🔍 [MOTION DEBUG] [\(timeString)]   ⚠️ Calling pedometer.startUpdates() - THIS WILL TRIGGER MOTION PERMISSION DIALOG IF NOT AUTHORIZED")
            pedometer.startUpdates(from: startDate) { [weak self] data, error in
                let callbackTime = Date()
                let callbackTimeString = formatter.string(from: callbackTime)
                if let error = error {
                    print("🔍 [MOTION DEBUG] [\(callbackTimeString)]   ⚠️ Pedometer callback error: \(error.localizedDescription)")
                }
                guard let data = data, error == nil else { return }
                
                DispatchQueue.main.async {
                    self?.stepCount = data.numberOfSteps.intValue
                    if let dist = data.distance {
                        self?.distance = dist.doubleValue
                    }
                }
            }
            print("🔍 [MOTION DEBUG] [\(timeString)]   ✅ pedometer.startUpdates() called")
        } else {
            print("🔍 [MOTION DEBUG] [\(timeString)]   ❌ Pedometer not available, skipping startUpdates")
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
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        print("🔍 [MOTION DEBUG] [\(timeString)] 🛑 stopObserving() CALLED")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Current Motion auth status: \(CMPedometer.authorizationStatus().rawValue)")
        print("🔍 [MOTION DEBUG] [\(timeString)]   pedometerStartDate was: \(pedometerStartDate?.description ?? "nil")")
        print("🔍 [MOTION DEBUG] [\(timeString)]   Call stack:")
        Thread.callStackSymbols.prefix(10).enumerated().forEach { index, symbol in
            print("🔍 [MOTION DEBUG] [\(timeString)]     [\(index)] \(symbol)")
        }
        
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
        
        print("🔍 [MOTION DEBUG] [\(timeString)]   ✅ stopObserving() completed - pedometer stopped")
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


