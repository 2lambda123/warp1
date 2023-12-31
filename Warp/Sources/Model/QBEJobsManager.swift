/* Warp. Copyright (C) 2014-2017 Pixelspark, Tommy van der Vorst

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, write to the Free
Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. */
import Foundation
import WarpCore

@objc internal protocol JobsManagerDelegate: NSObjectProtocol {
	func jobManager(_ manager: QBEJobsManager, jobDidStart: AnyObject)
	func jobManagerJobsProgressed(_ manager: QBEJobsManager)
}

internal class QBEJobsManager: NSObject, JobDelegate {
	class JobInfo: JobDelegate {
		weak var job: Job?
		weak var delegate: JobDelegate?
		let description: String
		var progress: Double
		private let mutex = Mutex()

		init(job: Job, description: String) {
			self.description = description
			self.job = job
			self.progress = 0.0
			job.addObserver(self)
		}

		@objc func job(_ job: AnyObject, didProgress progress: Double) {
			mutex.locked {
				self.progress = progress
			}
			// Forward the progress notification
			self.delegate?.job(job, didProgress: progress)
		}

		var running: Bool {
			return mutex.locked {
				return self.job != nil
			}
		}
	}

	private var observers: [Weak<JobsManagerDelegate>] = []
	private var jobs: [JobInfo] = []
	private let mutex = Mutex()

	override init() {
	}

	func addObserver(_ delegate: JobsManagerDelegate) {
		mutex.locked {
			self.observers.append(Weak(delegate))
		}
	}

	func removeObserver(_ delegate: JobsManagerDelegate) {
		mutex.locked {
			self.observers = self.observers.filter { w in
				if let observer = w.value {
					return observer !== delegate
				}
				return false
			}
		}
	}

	func addJob(_ job: Job, description: String) {
		let info = JobInfo(job: job, description: description)
		info.delegate = self
		mutex.locked {
			self.jobs.append(info)
		}
		self.observers.forEach { d in d.value?.jobManager(self, jobDidStart: job) }
	}

	private let progressUpdateInterval = 1.0
	private var lastProgressUpdate: Date? = nil
	private var progressUpdateScheduled = false

	@objc func job(_ job: AnyObject, didProgress progress: Double) {
		mutex.locked {
			if !progressUpdateScheduled {
				let now = NSDate()
				if let lp = lastProgressUpdate, now.timeIntervalSince(lp) < progressUpdateInterval {
					// Throttle
					progressUpdateScheduled = true
					DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + progressUpdateInterval) {
						self.mutex.locked {
							self.progressUpdateScheduled = false
							self.lastProgressUpdate = Date()
						}
						self.observers.forEach { d in d.value?.jobManagerJobsProgressed(self) }
					}
				}
				else {
					self.lastProgressUpdate = now as Date
					asyncMain {
						self.observers.forEach { d in d.value?.jobManagerJobsProgressed(self) }
					}
				}
			}
		}
	}

	private func clean() {
		mutex.locked {
			self.jobs = self.jobs.filter { $0.running }
			self.observers = self.observers.filter { $0.value != nil }
		}
	}

	var runningJobs: [JobInfo] {
		self.clean()
		return self.jobs.filter { $0.running }
	}
}
