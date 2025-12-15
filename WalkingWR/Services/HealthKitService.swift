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
    
    @Published var stepCount: Int = 0
    @Published var isAuthorized: Bool = false
    @Published var errorMessage: String?
    @Published var distance: Double = 0 // in meters from pedometer
    
    private var stepQuery: HKObserverQuery?
    private var pedometerStartDate: Date?
    
    // Types we want to read - only step count (no heart rate)
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    
    init() {
        checkAuthorization()
    }
    
    var isPedometerAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }
    
    var isPedometerAuthorized: Bool {
        CMPedometer.authorizationStatus() == .authorized
    }
    
    var isMotionAuthorized: Bool {
        // Check if Core Motion (pedometer) is authorized
        let status = CMPedometer.authorizationStatus()
        return status == .authorized
    }
    
    var isMotionDenied: Bool {
        let status = CMPedometer.authorizationStatus()
        return status == .denied || status == .restricted
    }
    
    var isMotionNotDetermined: Bool {
        let status = CMPedometer.authorizationStatus()
        return status == .notDetermined
    }
    
    /// Request Core Motion authorization by triggering a pedometer query
    func requestMotionAuthorization() {
        guard isPedometerAvailable else { return }
        
        // Trigger a brief pedometer query to prompt for permission
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        
        pedometer.queryPedometerData(from: oneMinuteAgo, to: now) { [weak self] _, _ in
            // After the query (which triggers the permission prompt), check status
            DispatchQueue.main.async {
                self?.objectWillChange.send()
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
        
        // For read-only access, authorizationStatus doesn't work
        // We need to try to query data to see if we have access
        // Check if we can read today's steps as a test
        Task {
            let hasAccess = await canReadStepData()
            await MainActor.run {
                self.isAuthorized = hasAccess
            }
        }
    }
    
    private func canReadStepData() async -> Bool {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)
        
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                // If we get a result (even if 0 steps) without error, we have access
                // If error is nil, we have access. Error means no access.
                if error == nil {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
            healthStore.execute(query)
        }
    }
    
    func requestAuthorization() async -> Bool {
        guard isHealthKitAvailable else {
            await MainActor.run {
                self.errorMessage = "HealthKit is not available on this device"
            }
            return false
        }
        
        let typesToRead: Set<HKObjectType> = [stepType]
        
        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            // For read access, we need to try reading data to know if access was granted
            let hasAccess = await canReadStepData()
            await MainActor.run {
                self.isAuthorized = hasAccess
            }
            return hasAccess
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
}


