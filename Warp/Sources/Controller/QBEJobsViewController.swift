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

class QBEJobViewController: NSViewController, JobDelegate {
	private var job: Job
	var jobDescription: String
	@IBOutlet var descriptionLabel: NSTextField!
	@IBOutlet var progressIndicator: NSProgressIndicator!

	init?(job: Job, description: String) {
		self.job = job
		self.jobDescription = description
		super.init(nibName: "QBEJobViewController", bundle: nil)
		job.addObserver(self)
	}

	required init?(coder: NSCoder) {
		fatalError("Not implemented")
	}

	override func viewWillAppear() {
		self.progressIndicator.startAnimation(nil)
		self.progressIndicator.isIndeterminate = true
		self.update()
	}

	override func viewWillDisappear() {
		self.progressIndicator.stopAnimation(nil)
	}

	@IBAction func cancel(_ sender: NSObject) {
		self.job.cancel()
		self.dismiss(sender)
	}

	private func update() {
		self.descriptionLabel?.stringValue = jobDescription
		self.progressIndicator.isIndeterminate = false
		self.progressIndicator.doubleValue = job.progress
	}

	func job(_ job: AnyObject, didProgress: Double) {
		asyncMain {
			self.update()
		}
	}
}

class JobsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, JobsManagerDelegate {
	@IBOutlet var tableView: NSTableView!
	var jobs: [QBEJobsManager.JobInfo] = []

	override func viewWillAppear() {
		QBEAppDelegate.sharedInstance.jobsManager.addObserver(self)
		self.view.window?.titlebarAppearsTransparent = true
		updateView()
	}

	override func viewWillDisappear() {
		QBEAppDelegate.sharedInstance.jobsManager.removeObserver(self)
	}

	func numberOfRows(in tableView: NSTableView) -> Int {
		return self.jobs.count
	}

	func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
		let info = jobs[row]

		switch tableColumn?.identifier.rawValue ?? "" {
			case "description": return info.description
			case "progress": return "\(info.progress)"
			default: return nil
		}
	}

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let info = jobs[row]

		switch tableColumn?.identifier.rawValue ?? "" {
		case "description":
			let vw = NSTextField()
			vw.isBordered = false
			vw.backgroundColor = NSColor.clear
			vw.stringValue = info.description
			return vw

		case "progress":
			let vw = NSProgressIndicator()
			vw.style = .bar
			vw.isIndeterminate = false
			vw.doubleValue = info.progress
			vw.maxValue = 1.0
			vw.minValue = 0.0
			return vw

		default: return nil
		}
	}

	private func updateView() {
		assertMainThread()
		self.jobs = QBEAppDelegate.sharedInstance.jobsManager.runningJobs
		self.tableView?.reloadData()
	}

	func jobManager(_ manager: QBEJobsManager, jobDidStart: AnyObject) {
		asyncMain {
			self.updateView()
		}
	}

	func jobManagerJobsProgressed(_ manager: QBEJobsManager) {
		asyncMain {
			self.updateView()
		}
	}
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromNSUserInterfaceItemIdentifier(_ input: NSUserInterfaceItemIdentifier) -> String {
	return input.rawValue
}
