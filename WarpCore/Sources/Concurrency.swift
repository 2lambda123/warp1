/* Copyright (c) 2014-2016 Pixelspark, Tommy van der Vorst

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */
import Foundation

/** Log a message through the main dispatch queue (to prevent messages from being mingled, as Swift.print does not
appear to be thread-safe). Trace messages are not emitted in release builds. */
public func trace(_ message: String, file: StaticString = #file, line: UInt = #line) {
	#if DEBUG
		DispatchQueue.main.async {
			print(message)
		}
	#endif
}

/** Asserts that the thread calling this function is the main thread. This can be used to ensure that code that must run
on the main thread never runs on another. */
public func assertMainThread(_ file: StaticString = #file, line: UInt = #line) {
	assert(Thread.isMainThread, "Code at \(file):\(line) must run on main thread!")
}

/** Wrap a block so that it can be called only once. Calling the returned block twice results in a fatal error. After
the first call but before returning the result from the wrapped block, the wrapped block is dereferenced. */
////public func once<P, R>(_ block: @escaping (P) -> R) -> (P) -> R {
public func once<P, R>(_ block: @escaping (P) -> R) -> (P) -> R {
	#if DEBUG
		var blockReference: ((P) -> (R))? = block
		let mutex = Mutex()

		return {(p: P) -> (R) in
			let block = mutex.locked { () -> ((P) -> (R)) in
				assert(blockReference != nil, "callback called twice!")
				let r = blockReference!
				blockReference = nil
				return r
			}

			return block(p)
		}
	#else
		return block
	#endif
}

public func once2<P, Q, R>(_ block: @escaping (P, Q) -> R) -> (P, Q) -> R {
	#if DEBUG
		var blockReference: ((P, Q) -> (R))? = block
		let mutex = Mutex()

		return {(p: P, q: Q) -> (R) in
			let block = mutex.locked { () -> ((P, Q) -> (R)) in
				assert(blockReference != nil, "callback called twice!")
				let r = blockReference!
				blockReference = nil
				return r
			}

			return block(p, q)
		}
	#else
		return block
	#endif
}

/** This helper function can be used to create a lazily-computed variable, in a thread-safe way. */
func memoize<T>(_ result: @escaping () -> T) -> () -> T {
	var cached: T? = nil
	let mutex = Mutex()

	return {() in
		return mutex.locked {
			if let v = cached {
				return v
			}
			else {
				cached = result()
				return cached!
			}
		}
	}
}

/** Throttle wraps a block with throttling logic, guarantueeing that the block will never be called (by enquueing 
asynchronously on `queue`) more than once each `interval` seconds. If the wrapper callback is called more than once
in an interval, it will use the most recent call's parameters when eventually calling the wrapped block (after `interval`
has elapsed since the last call to the wrapped function) - i.e. calls are not queued and may get 'lost' by being superseded
by a newer call. */
public func throttle<P>(interval: TimeInterval, queue: DispatchQueue, _ block: @escaping ((P) -> ())) -> ((P) -> ()) {
	var lastExecutionTime: TimeInterval? = nil
	var scheduledExecutionParameters: P? = nil
	let mutex = Mutex()

	return { (p: P) -> () in
		return mutex.locked {
			let currentTime = NSDate.timeIntervalSinceReferenceDate

			if let lastExecuted = lastExecutionTime {
				if (currentTime - lastExecuted) > interval {
					// Not the first execution, but the last execution was more than interval ago. Execute now.
					lastExecutionTime = currentTime
					queue.async {
						block(p)
					}
				}
				else {
					// Last execution was less than interval ago
					if scheduledExecutionParameters != nil {
						// Another execution was already planned, just mae sure it will use latest parameters
						scheduledExecutionParameters = p
					}
					else {
						// Schedule execution
						scheduledExecutionParameters = p
						let scheduleDelay = lastExecuted + interval - currentTime

						queue.asyncAfter(deadline: DispatchTime.now() + scheduleDelay) {
							// Delayed execution
							let p = mutex.locked { () -> P in
								let params = scheduledExecutionParameters!
								scheduledExecutionParameters = nil
								return params
							}
							block(p)
						}
					}
				}
			}
			else {
				// First time this function is executed
				lastExecutionTime = currentTime
				queue.async {
					block(p)
				}
			}
		}
	}
}

/** Runs the given block of code asynchronously on the main queue. */
public func asyncMain(_ block: @escaping () -> ()) {
	DispatchQueue.main.async(execute: block)
}

/** Extensions to process sequences in parallel. */
/*public extension Sequence {
	typealias Element = Iterator.Element
	
	/** Iterate over the items in this array, and call the 'each' block for each element. At most `maxConcurrent` calls
	to `each` may be 'in flight' concurrently. After each has been called and called back for each of the items, the
	completion block is called. */
	func eachConcurrently(_ maxConcurrent: Int, maxPerSecond: Int?, each: @escaping (Element, @escaping () -> ()) -> (), completion: @escaping () -> ()) {
		let s = self as! AnySequence<Element>
		_eachConcurrently(s, maxConcurrent: maxConcurrent, maxPerSecond: maxPerSecond, each: each, completion: completion)
	}
}*/

public func eachConcurrently<Element>(_ s: AnySequence<Element>, maxConcurrent: Int, maxPerSecond: Int?, each: @escaping (Element, @escaping () -> ()) -> (), completion: @escaping () -> ()) {
	let iterator = s.makeIterator()
	let mutex = Mutex()
	var outstanding = 0

	func eachTimed(_ element: Element) {
		let start = CFAbsoluteTimeGetCurrent()
		each(element, {
			let end = CFAbsoluteTimeGetCurrent()
			advance(end - start)
		})
	}

	func advance(_ duration: Double) {
		// There are more elements, call the each function on the next one
		if let next = iterator.next() {
			/* If we can make at most x requests per second, each request should take at least
			1/x seconds if we would be executing these requests serially. Because we have n
			concurrent requests, each request needs to take at least n/x seconds. */
			if let mrps = maxPerSecond {
				let minimumTime = Double(maxConcurrent) / Double(mrps)
				if minimumTime > duration {
					DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64((minimumTime - duration) * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
						eachTimed(next)
					}
					return
				}
			}
			eachTimed(next)
		}
		else {
			mutex.locked {
				outstanding -= 1
				// No elements left to call each for, but there may be some elements in flight. The last one calls completion
				if outstanding == 0 {
					completion()
				}
			}
		}
	}

	// Call `each` for at most maxConcurrent items
	var atLeastOne = false
	for _ in 0..<maxConcurrent {
		if let next = iterator.next() {
			atLeastOne = true
			mutex.locked {
				outstanding += 1
			}
			eachTimed(next)
		}
	}

	if !atLeastOne {
		completion()
	}
}

internal extension Array {
	func parallel<T, ResultType>(_ map: (@escaping (Array<Element>) -> (T)), reduce: (@escaping (T, ResultType?) -> (ResultType))) -> Future<ResultType?> {
		let chunkSize = StreamDefaultBatchSize/8
		
		return Future<ResultType?>({ (job, completion) -> () in
			let group = DispatchGroup()
			var buffer: [T] = []
			var finishedItems = 0
			
			// Chunk the contents of the array and dispatch jobs that map each chunk
			for i in stride(from: 0, to: self.count, by: chunkSize) {
				let x = i + chunkSize
				let n = (x < self.count) ? x : self.count

				let view = Array(self[i..<n])
				let count: Int = view.count
				
				job.queue.async(group: group) {
					// Check whether we still need to process this chunk
					if job.cancelled {
						return
					}
					
					// Generate output for this chunk
					let workerOutput = map(view)
					
					// Dispatch a block that adds our result (synchronously) to the intermediate result buffer
					DispatchQueue.main.async(group: group) {
						finishedItems += count
						let p = Double(finishedItems) / Double(self.count)
						job.reportProgress(p, forKey: 1)
						buffer.append(workerOutput)
					}
				}
			}
			
			// Reduce stage: loop over all intermediate results in the buffer and merge
			group.notify(queue: job.queue) {
				if job.cancelled {
					return
				}
				
				var result: ResultType? = nil
				for item in buffer {
					result = reduce(item, result)
				}
				
				completion(result)
			}
		}, timeLimit: nil)
	}
}

@objc public protocol JobDelegate {
	func job(_ job: AnyObject, didProgress: Double)
}

/** Fallible<T> represents the outcome of an operation that can either fail (with an error message) or succeed 
(returning an instance of T). */
public enum Fallible<T> {
	case success(T)
	case failure(String)
	
	public init<P>(_ other: Fallible<P>) {
		switch other {
			case .success(let s):
				self = .success(s as! T)
			
			case .failure(let e):
				self = .failure(e)
		}
	}
	
	/** If the result is successful, execute `block` on its return value, and return the (fallible) return value of that block
	(if any). Otherwise return a new, failed result with the error message of this result. This can be used to chain 
	operations on fallible operations, propagating the error once an operation fails. */
	public func use<P>( _ block: (T) -> P) -> Fallible<P> {
		switch self {
			case .success(let value):
				return .success(block(value))
			
			case .failure(let errString):
				return .failure(errString)
		}
	}

	public func use<P>( _ block: (T) -> Fallible<P>) -> Fallible<P> {
		switch self {
		case .success(let box):
			return block(box)
			
		case .failure(let errString):
			return .failure(errString)
		}
	}
	
	/** If this result is a success, execute the block with its value. Otherwise cause a fatal error.  */
	public func require( _ block: (T) -> Void) {
		switch self {
		case .success(let value):
			block(value)
			
		case .failure(let errString):
			fatalError("Cannot continue with failure: \(errString)")
		}
	}

	/** If this result is a success, execute the block with its value. Otherwise silently ignore the failure (but log in debug mode) */
	public func maybe( _ block: (T) -> Void) {
		switch self {
		case .success(let value):
			block(value)
			
		case .failure(let errString):
			trace("Silently ignoring failure: \(errString)")
		}
	}
}

public class Weak<T: AnyObject>: NSObject {
	public private(set) weak var value: T?
	
	public init(_ value: T?) {
		self.value = value
	}
}

/** A Job represents a single asynchronous calculation. Job tracks the progress and cancellation status of a single
'job'. It is generally passed along to all functions that also accept an asynchronous callback. The Job object should 
never be stored by these functions. It should be passed on by the functions to any other asynchronous operations that 
belong to the same job. The Job has an associated dispatch queue in which any asynchronous operations that belong to
the job should be executed (the shorthand function Job.async can be used for this).

Job can be used to track the progress of a job's execution. Components in the job can report their progress using the
reportProgress call. As key, callers should use a unique value (e.g. their own hashValue). The progress reported by Job
is the average progress of all components.

When used with Future, a job represents a single attempt at the calculation of a future. The 'producer' callback of a 
Future receives the Job object and should use it to check whether calculation of the future is still necessary (or
the job has been cancelled) and report progress information. */
public class Job: JobDelegate {
	public let queue: DispatchQueue
	let parentJob: Job?
	fileprivate var cancelled: Bool = false
	private var progressComponents: [Int: Double] = [:]
	private var observers: [Weak<JobDelegate>] = []
	fileprivate let mutex = Mutex()

	#if DEBUG
	private static let jobCounterMutex = Mutex()
	private static var jobCounter = 0
	private let jobID: Int
	#endif
	
	public init(_ qos: DispatchQoS) {
		#if DEBUG
			self.jobID = Job.jobCounterMutex.locked {
				 let jobNumber = Job.jobCounter + 1
				 Job.jobCounter += 1
				 return  jobNumber
			}

			self.queue = DispatchQueue(label: "Job \(self.jobID)", qos: qos, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
		#else
			self.queue = DispatchQueue(label: "nl.pixelspark.Warp.Job", qos: qos, attributes: [.concurrent], autoreleaseFrequency: .inherit, target: nil)
		#endif

		self.parentJob = nil
	}
	
	public init(parent: Job) {
		self.parentJob = parent
		self.queue = parent.queue

		#if DEBUG
			self.jobID = Job.jobCounterMutex.locked {
				let jobNumber = Job.jobCounter + 1
				Job.jobCounter += 1
				return  jobNumber
			}
		#endif

		parent.reportProgress(0.0, forKey: Unmanaged.passUnretained(self).toOpaque().hashValue)
	}
	
	fileprivate init(queue: DispatchQueue) {
		self.queue = queue
		self.parentJob = nil

		#if DEBUG
			self.jobID = Job.jobCounterMutex.locked {
				let jobNumber = Job.jobCounter + 1
				Job.jobCounter += 1
				return  jobNumber
			}
		#endif
	}

	#if DEBUG
	deinit {
		log("Job deinit; \(timeComponents)")
	}
	#endif

	public var isCancelled: Bool {
		return self.mutex.locked {
			return self.cancelled
		}
	}
	
	/** Shorthand function to run a block asynchronously in the queue associated with this job. Because async() will often
	be called with an 'expensive' block, it also checks the jobs cancellation status. If the job is cancelled, the block
	will not be executed, nor will any timing information be reported. */
	public func async(_ block: @escaping () -> ()) {
		if isCancelled {
			return
		}
		
		if let p = parentJob, p.isCancelled {
			return
		}
		
		queue.async(execute: block)
	}
	
	/** Records the time taken to execute the given block and writes it to the console. In release builds, the block is 
	simply called and no timing information is gathered. Because time() will often be called with an 'expensive' block, 
	it also checks the jobs cancellation status. If the job is cancelled, the block will not be executed, nor will any 
	timing information be reported. */
	public func time(_ description: String, items: Int, itemType: String, block: () -> ()) {
		if self.isCancelled {
			return
		}
		
		if let p = parentJob, p.isCancelled {
			return
		}
		
		#if DEBUG
			let t = CFAbsoluteTimeGetCurrent()
			block()
			let d = CFAbsoluteTimeGetCurrent() - t

			if items > 0 {
				log("\(description)\t\(items) \(itemType):\t\(round(10*Double(items)/d)/10) \(itemType)/s")
			}
			self.reportTime(description, time: d)
		#else
			block()
		#endif
	}
	
	public func addObserver(_ observer: JobDelegate) {
		mutex.locked {
			self.observers.append(Weak(observer))

			// Broadcast progress now so the new observer can add this job to its progress components list
			self.broadcastProgress()
		}
	}
	
	/** Inform anyone waiting on this job that a particular sub-task has progressed. Progress needs to be between 0...1,
	where 1 means 'complete'. Callers of this function should generate a sufficiently unique key that identifies the sub-
	operation in the job of which the progress is reported (e.g. use '.hash' on an object private to the subtask). */
	public func reportProgress(_ progress: Double, forKey: Int, file: StaticString = #file, line: UInt = #line) {
		assert(!progress.isNaN && progress >= 0.0 && progress <= 1.0, "invalid progress reported: \(progress)")

		mutex.locked {
 			#if DEBUG
				if self.progressComponents[forKey] == nil && self.progress > 0 {
					log("Adding progress component after having progressed \(self.progress), progressing backwards [\(file):\(line)]")
				}
			#endif

			self.progressComponents[forKey] = progress
			self.broadcastProgress()
		}
	}

	private func broadcastProgress() {
		self.mutex.locked {
			let currentProgress = self.progress
			assert(!currentProgress.isNaN && currentProgress >= 0.0 && currentProgress <= 1.0, "invalid current progress")
			for observer in self.observers {
				observer.value?.job(self, didProgress: currentProgress)
			}

			// Report our progress back up to our parent
			self.parentJob?.reportProgress(currentProgress, forKey: Unmanaged.passUnretained(self).toOpaque().hashValue)
		}
	}
	
	/** Returns the estimated progress of the job by multiplying the reported progress for each component. The progress is
	represented as a double between 0...1 (where 1 means 'complete'). Progress is not guaranteed to monotonically increase
	or to ever reach 1. */
	public var progress: Double { get {
		return mutex.locked {
			var sumProgress = 0.0
			var items = 0
			for (_, p) in self.progressComponents {
				sumProgress += p
				items += 1
			}
			
			return items > 0 ? (sumProgress / Double(items)) : 0.0;
		}
	} }
	
	/** Marks this job as 'cancelled'. Any blocking operation running in this job should periodically check the cancelled
	status, and abort if the job was cancelled. Calling cancel() does not guarantee that any operations are actually
	cancelled. */
	public func cancel() {
		mutex.locked {
			self.cancelled = true
		}
	}
	
	@objc public func job(_ job: AnyObject, didProgress: Double) {
		self.reportProgress(didProgress, forKey: Unmanaged.passUnretained(self).toOpaque().hashValue)
	}
	
	/** Print a message to the debug log. The message is sent to the console asynchronously (but ordered) and prepended
	with the 'job ID'. No messages will be logged when not compiled in debug mode. */
	public func log(_ message: String, file: StaticString = #file, line: UInt = #line) {
		#if DEBUG
			let id = self.jobID
			DispatchQueue.main.async {
				print("[\(id)] \(message)")
			}
		#endif
	}

	#if DEBUG
	private var timeComponents: [String: Double] = [:]
	
	func reportTime(_ component: String, time: Double) {
		mutex.locked {
			if let t = self.timeComponents[component] {
				self.timeComponents[component] = t + time
			}
			else {
				self.timeComponents[component] = time
			}
		}
	}
	#endif
}

/** A pthread-based recursive mutex lock. */
public class Mutex {
	private var mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

	#if DEBUG
	private var locker: String? = nil
	#endif

	public init() {
		var attr: pthread_mutexattr_t = pthread_mutexattr_t()
		pthread_mutexattr_init(&attr)
		pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE)

		mutex.initialize(to: pthread_mutex_t())
		let err = pthread_mutex_init(mutex, &attr)
		pthread_mutexattr_destroy(&attr)

		switch err {
		case 0:
			// Success
			break

		case EAGAIN:
			fatalError("Could not create mutex: EAGAIN (The system temporarily lacks the resources to create another mutex.)")

		case EINVAL:
				fatalError("Could not create mutex: invalid attributes")

		case ENOMEM:
			fatalError("Could not create mutex: no memory")

		default:
			fatalError("Could not create mutex, unspecified error \(err)")
		}
	}

	private final func lock() {
		let ret = pthread_mutex_lock(mutex)
		switch ret {
		case 0:
			// Success
			break

		case EDEADLK:
			fatalError("Could not lock mutex: a deadlock would have occurred")

		case EINVAL:
			fatalError("Could not lock mutex: the mutex is invalid")

		default:
			fatalError("Could not lock mutex: unspecified error \(ret)")
		}
	}

	private final func unlock() {
		let ret = pthread_mutex_unlock(mutex)
		switch ret {
		case 0:
			// Success
			break

		case EPERM:
			fatalError("Could not unlock mutex: thread does not hold this mutex")

		case EINVAL:
			fatalError("Could not unlock mutex: the mutex is invalid")

		default:
			fatalError("Could not unlock mutex: unspecified error \(ret)")
		}
	}

	deinit {
		assert(pthread_mutex_trylock(mutex) == 0 && pthread_mutex_unlock(mutex) == 0, "deinitialization of a locked mutex results in undefined behavior!")
		pthread_mutex_destroy(mutex)
	}

	/** Execute the given block while holding a lock to this mutex. */
	@discardableResult public final func locked<T>(_ file: StaticString = #file, line: UInt = #line, block: () throws -> (T)) rethrows -> T {
		#if DEBUG
			let start = CFAbsoluteTimeGetCurrent()
		#endif
		self.lock()
		#if DEBUG
			if Thread.isMainThread {
				let duration = CFAbsoluteTimeGetCurrent() - start
				if duration > 0.05 {
					trace("Waited \(duration)s  on main thread for mutex (\(file):\(line)) last locked by \(String(describing: self.locker))")
				}
				self.locker = "\(file):\(line)"
			}
		#endif

		defer {
			self.unlock()
		}
		let ret: T = try block()
		return ret
	}
}

/** Future represents a result of a (potentially expensive) calculation. Code that needs the result of the
operation express their interest by enqueuing a callback with the get() function. The callback gets called immediately
if the result of the calculation was available in cache, or as soon as the result has been calculated. **/


/** The calculation itself is done by the 'producer' block. When the producer block is changed, the cached result is
invalidated (pre-registered callbacks may still receive the stale result when it has been calculated). */
public class Future<T> {
	public typealias Callback = (T) -> Void
	public typealias Producer = (Job, @escaping Callback) -> Void

	fileprivate var batch: Batch<T>?
	fileprivate let mutex: Mutex = Mutex()
	
	let producer: Producer
	let timeLimit: Double?
	
	public init(_ producer: @escaping Producer, timeLimit: Double? = nil)  {
		let p = once2(producer)
		self.producer = p
		self.timeLimit = timeLimit
	}
	
	private func calculate() {
		self.mutex.locked {
			assert(batch != nil, "calculate() called without a current batch")
			
			if let batch = self.batch {
				if let tl = timeLimit {
					// Set a timer to cancel this job
					DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(tl * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
						batch.log("Timed out after \(tl) seconds")
						batch.expire()
					}
				}
				batch.async {
					self.producer(batch, batch.satisfy)
				}
			}
		}
	}
	
	/** Abort calculating the result (if calculation is in progress). Registered callbacks will not be called (when 
	callbacks are already being called, this will be finished).*/
	public func cancel() {
		self.mutex.locked {
			batch?.cancel()
		}
	}
	
	/** Abort calculating the result (if calculation is in progress). Registered callbacks may still be called. */
	public func expire() {
		self.mutex.locked {
			batch?.expire()
		}
	}
	
	public var cancelled: Bool { get {
		return self.mutex.locked { () -> Bool in
			return batch?.cancelled ?? false
		}
	} }
	
	/** Returns the result of the current calculation run, or nil if that calculation hasn't started yet or is still
	 running. Use get() to start a calculation and await the result. */
	public var result: T? { get {
		return self.mutex.locked {
			return batch?.cached ?? nil
		}
	} }
	
	/** Request the result of this future. There are three scenarios:
	- The future has not yet been calculated. In this case, calculation will start in the queue specified in the `queue`
	  variable. The callback will be enqueued to receive the result as soon as the calculation finishes. 
	- Calculation of the future is in progress. The callback will be enqueued on a waiting list, and will be called as 
	  soon as the calculation has finished.
	- The future has already been calculated. In this case the callback is called immediately with the result.
	
	Note that the callback may not make any assumptions about the queue or thread it is being called from. Callees should
	therefore not block. 
	
	The get() function performs work in its own Job.	If a job is set as parameter, this job will be a child of the 
	given job, and will use its preferred queue. Otherwise it will perform the work in the user initiated QoS concurrent
	queue. This function always returns its own child Job. */
	@discardableResult public func get(_ job: Job, _ callback: @escaping Callback) -> Job {
		return self.mutex.locked {
			var first = false

			if self.batch == nil {
				first = true
				self.batch = Batch<T>(parent: job)
			}

			batch!.enqueue(callback)

			if(first) {
				calculate()
			}

			return batch!
		}
	}
}

/** A MutableFuture is like a future, but (1) it does not obtain its result from a producer but is externally satisfied, 
and (2) it can be satisfied multiple times. */
public class MutableFuture<T>: Future<T> {
	public init() {
		super.init({ (job, callback) in
			// Never calls back
		})
	}

	public func satisfy(_ value: T, queue: DispatchQueue = DispatchQueue.main) {
		self.mutex.locked {
			if self.batch == nil || self.batch!.satisfied {
				self.batch = Batch<T>(queue: queue)
			}
			self.batch?.satisfy(value)
		}
	}
}

class Batch<T>: Job {
	typealias Callback = Future<T>.Callback
	fileprivate var cached: T? = nil
	private var waitingList: [Callback] = []
	
	fileprivate var satisfied: Bool {
		return self.mutex.locked {
			return cached != nil
		}
	}
	
	override init(queue: DispatchQueue) {
		super.init(queue: queue)
	}
	
	override init(parent: Job) {
		super.init(parent: parent)
	}
	
	/** Called by a producer to return the result of a job. This method will call all callbacks on the waiting list (on the
	main thread) and subsequently empty the waiting list. Enqueue can only be called once on a batch. */
	func satisfy(_ value: T) {
		self.mutex.locked {
			assert(cached == nil, "Batch.satisfy called with cached!=nil: \(String(describing: cached)) \(value)")
			assert(!satisfied, "Batch already satisfied")

			self.cached = value
			for waiting in self.waitingList {
				self.async {
					waiting(value)
				}
			}
			self.waitingList = []
		}
	}
	
	/** Expire is like cancel, only the waiting consumers are not removed from the waiting list. This allows a job to
	return a partial result (by calling the callback while job.cancelled is already true) */
	func expire() {
		self.mutex.locked {
			if !self.satisfied {
				self.cancelled = true
			}
		}
	}
	
	/** Cancel this job and remove all waiting listeners (they will never be called back). */
	override func cancel() {
		self.mutex.locked {
			if !self.satisfied {
				self.waitingList.removeAll(keepingCapacity: false)
				self.cancelled = true
			}
			super.cancel()
		}
	}
	
	func enqueue(_ callback: @escaping Callback) {
		self.mutex.locked {
			if satisfied {
				let c = self.cached!
				self.queue.async {
					callback(c)
				}
			}
			else {
				#if DEBUG
				if cancelled {
					log("Enqueueing on a cancelled future - callback will not be called!")
				}
				#endif

				if !cancelled {
					self.waitingList.append(callback)
				}
			}
		}
	}
}
