//
//  AsyncValueSubject.swift
//  Supabase
//
//  Created by Guilherme Souza on 31/10/24.
//

import Foundation

/// A thread-safe subject that wraps a single value and provides async access to its updates.
/// Similar to Combine's CurrentValueSubject, but designed for async/await usage.
package actor AsyncValueSubject<Value: Sendable> {

  /// Defines how values are buffered in the underlying AsyncStream.
  package typealias BufferingPolicy = AsyncStream<Value>.Continuation.BufferingPolicy

  private var value: Value
  private var continuations: [UInt: AsyncStream<Value>.Continuation] = [:]
  private var count: UInt = 0
  private var finished = false
  private let bufferingPolicy: BufferingPolicy

  /// Creates a new AsyncValueSubject with an initial value.
  /// - Parameters:
  ///   - initialValue: The initial value to store
  ///   - bufferingPolicy: Determines how values are buffered in the AsyncStream (defaults to .unbounded)
  package init(_ initialValue: Value, bufferingPolicy: BufferingPolicy = .unbounded) {
    self.value = initialValue
    self.bufferingPolicy = bufferingPolicy
  }

  deinit {
    Task { await finish() }
  }

  /// The current value stored in the subject.
  package var currentValue: Value {
    value
  }

  /// Resume the task awaiting the next iteration point by having it return normally from its suspension point with a given element.
  /// - Parameter value: The value to yield from the continuation.
  ///
  /// If nothing is awaiting the next value, this method attempts to buffer the result's element.
  ///
  /// This can be called more than once and returns to the caller immediately without blocking for any awaiting consumption from the iteration.
  package func yield(_ value: Value) {
    guard !finished else { return }
    
    self.value = value
    for (_, continuation) in continuations {
      continuation.yield(value)
    }
  }

  /// Resume the task awaiting the next iteration point by having it return
  /// nil, which signifies the end of the iteration.
  ///
  /// Calling this function more than once has no effect. After calling
  /// finish, the stream enters a terminal state and doesn't produce any
  /// additional elements.
  package func finish() {
    guard !finished else { return }
    
    finished = true
    
    for (_, continuation) in continuations {
      continuation.finish()
    }
    continuations.removeAll()
  }

  /// An AsyncStream that emits the current value and all subsequent updates.
  package nonisolated var values: AsyncStream<Value> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
      Task { await insert(continuation) }
    }
  }

  /// Observes changes to the subject's value by executing the provided handler.
  /// - Parameters:
  ///   - priority: The priority of the task that will observe changes (optional)
  ///   - handler: A closure that will be called with each new value
  /// - Returns: A task that can be cancelled to stop observing changes
  @discardableResult
  package nonisolated func onChange(
    priority: TaskPriority? = nil,
    _ handler: @escaping @Sendable (Value) -> Void
  ) -> Task<Void, Never> {
    let stream = self.values
    return Task(priority: priority) {
      for await value in stream {
        if Task.isCancelled {
          break
        }
        handler(value)
      }
    }
  }

  /// Adds a new continuation to the subject and yields the current value.
  private func insert(_ continuation: AsyncStream<Value>.Continuation) {
    guard !finished else {
      continuation.finish()
      return
    }
    
    continuation.yield(value)
    count += 1
    let id = count
    continuations[id] = continuation
    
    continuation.onTermination = { [weak self] _ in
      Task { await self?.remove(continuation: id) }
    }
  }

  /// Removes a continuation when it's terminated.
  private func remove(continuation id: UInt) {
    _ = continuations.removeValue(forKey: id)
  }
}

extension AsyncValueSubject where Value == Void {
  package func yield() async {
    await self.yield(())
  }
}