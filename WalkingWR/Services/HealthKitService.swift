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
    @Published var heartRate: Double = 0
    @Published var isAuthorized: Bool = false
    @Published var errorMessage: String?
    @Published var distance: Double = 0 // in meters from pedometer
    
    private var stepQuery: HKObserverQuery?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var pedometerStartDate: Date?
    
    // Types we want to read
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    
    init() {
        checkAuthorization()
    }
    
    var isPedometerAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }
    
    var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }
    
    func checkAuthorization() {
        guard isHealthKitAvailable else {
            errorMessage = "HealthKit is not available on this device"
            return
        }
        
        let status = healthStore.authorizationStatus(for: stepType)
        isAuthorized = status == .sharingAuthorized
    }
    
    func requestAuthorization() async -> Bool {
        guard isHealthKitAvailable else {
            errorMessage = "HealthKit is not available on this device"
            return false
        }
        
        let typesToRead: Set<HKObjectType> = [stepType, heartRateType]
        
        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            await MainActor.run {
                self.isAuthorized = true
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
    
    func startObservingHeartRate() {
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-60),
            end: nil,
            options: .strictStartDate
        )
        
        heartRateQuery = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, error in
            self?.processHeartRateSamples(samples)
        }
        
        heartRateQuery?.updateHandler = { [weak self] _, samples, _, _, error in
            self?.processHeartRateSamples(samples)
        }
        
        if let query = heartRateQuery {
            healthStore.execute(query)
        }
    }
    
    private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let heartRateSamples = samples as? [HKQuantitySample],
              let mostRecent = heartRateSamples.last else { return }
        
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let value = mostRecent.quantity.doubleValue(for: heartRateUnit)
        
        DispatchQueue.main.async {
            self.heartRate = value
        }
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
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
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


