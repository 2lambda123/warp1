/* Warp. Copyright (C) 2014-2017 Pixelspark, Tommy van der Vorst

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, write to the Free
Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. */
import Cocoa

class QBETourWindowController: NSWindowController {
	override var document: AnyObject? {
		didSet {
			if let tourViewController = window!.contentViewController as? QBETourViewController {
				tourViewController.document = document as? QBEDocument
			}
		}
	}
}

/** The tour controller facilitates a 'guided tour' consisting of a slide show of images and texts. The images are named
images included as resource with the app, and the texts are set in a strings file. 

The tour is usually started at the point where normally a document view controller would be instantiated. The tour 
controller keeps hold of the document while the tour is running, and will instantiate the normal document view controller
afterwards. The following code snipped can be added to an NSDocument:

override func makeWindowControllers() {
	let storyboard = NSStoryboard(name: "Main", bundle: nil)

	if tour {
		let ctr = storyboard.instantiateControllerWithIdentifier("tour") as! NSWindowController
		self.addWindowController(ctr)
	}
	else {
		let windowController = storyboard.instantiateControllerWithIdentifier("documentWindow") as! NSWindowController
		self.addWindowController(windowController)
	}
} */
class QBETourViewController: NSViewController {
	/** Prefix for the text strings in the tour. The strings table should contain strings for "prefix.#.title" and
	"prefix.#.description", where '#' is the step number (starting at 0) and 'prefix' is the prefix set here. */
	var tourStringsPrefix = "tour"

	/** Tour images have a name prefixed with tourAssetPrefix, followed by the step number (e.g. Tour0, Tour1, ..) */
	var tourAssetPrefix = "Tour"

	/** The name of the strings table that contains the tour's texts */
	var tourStringsTable = "Tour"

	/* // The number of items in this tour */
	var tourItemCount = 8

	/** If a document is set, the tour controller will open it after the tour has finished, in its document view. If no
	 document is set, the tour will just close. */
	var document: QBEDocument? = nil

	private var currentStep = 0
	@IBOutlet var imageView: NSImageView!
	@IBOutlet var textView: NSTextField!
	@IBOutlet var subTextView: NSTextField!
	@IBOutlet var animatedView: NSView!
	@IBOutlet var pageLabel: NSTextField!
	@IBOutlet var nextButton: NSButton!
	@IBOutlet var skipButton: NSButton!

	private func nextStep(_ animated: Bool) {
		if animated {
			let tr = CATransition()
			tr.duration = 0.3
			tr.type = convertToCATransitionType(convertFromCATransitionType(CATransitionType.fade))
			tr.subtype = convertToOptionalCATransitionSubtype(convertFromCATransitionSubtype(CATransitionSubtype.fromRight))
			tr.timingFunction = CAMediaTimingFunction(name: convertToCAMediaTimingFunctionName(convertFromCAMediaTimingFunctionName(CAMediaTimingFunctionName.easeOut)))
			animatedView.layer?.add(tr, forKey: kCATransition)
		}
		self.currentStep += 1
		updateView()
	}

	@IBAction func endTour(_ sender: NSObject) {
		if let d = document, let ownController = self.view.window?.windowController {
			d.removeWindowController(ownController)
			d.makeWindowControllers()

			if let w = d.windowControllers.first?.window, let ownWindow = self.view.window {
				w.setFrame(ownWindow.convertToScreen(self.view.convert(self.imageView.frame, to: nil)), display: false)
			}
			d.showWindows()
			self.document = nil
		}
		self.view.window?.close()
	}

	private func updateView() {
		pageLabel.isHidden = currentStep == (tourItemCount) || currentStep == 0
		skipButton.isHidden = pageLabel.isHidden

		if currentStep == 0 {
			nextButton.title = NSLocalizedString("Okay, show me!", comment: "")
		}
		else if currentStep == tourItemCount {
			nextButton.title = NSLocalizedString("Get started", comment: "")
		}
		else {
			nextButton.title = NSLocalizedString("Got it!", comment: "")
		}
		
		pageLabel.stringValue = currentStep > 0 ? String(format:NSLocalizedString("Step %d of %d", comment: ""), currentStep, tourItemCount - 1) : ""
		imageView.image = NSImage(named: "\(tourAssetPrefix)\(self.currentStep)")
		textView.stringValue = NSLocalizedString("\(tourStringsPrefix).\(currentStep).title", tableName: self.tourStringsTable, bundle: Bundle.main, value: "", comment: "")
		subTextView.stringValue = NSLocalizedString("\(tourStringsPrefix).\(currentStep).description", tableName: self.tourStringsTable, bundle: Bundle.main, value: "", comment: "")
	}

	@IBAction func next(_ sender: NSObject) {
		if currentStep < tourItemCount {
			nextStep(true)
		}
		else {
			endTour(sender)
		}
	}

	override func viewWillAppear() {
		self.currentStep = 0
		self.view.window?.center()
		self.view.window?.titlebarAppearsTransparent = true
		self.view.window?.titleVisibility = NSWindow.TitleVisibility.hidden
		self.view.window?.isMovableByWindowBackground = true
		updateView()
	}

    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToCATransitionType(_ input: String) -> CATransitionType {
	return CATransitionType(rawValue: input)
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromCATransitionType(_ input: CATransitionType) -> String {
	return input.rawValue
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToOptionalCATransitionSubtype(_ input: String?) -> CATransitionSubtype? {
	guard let input = input else { return nil }
	return CATransitionSubtype(rawValue: input)
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromCATransitionSubtype(_ input: CATransitionSubtype) -> String {
	return input.rawValue
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToCAMediaTimingFunctionName(_ input: String) -> CAMediaTimingFunctionName {
	return CAMediaTimingFunctionName(rawValue: input)
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromCAMediaTimingFunctionName(_ input: CAMediaTimingFunctionName) -> String {
	return input.rawValue
}
