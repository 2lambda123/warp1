/* Warp. Copyright (C) 2014-2017 Pixelspark, Tommy van der Vorst

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, write to the Free
Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. */
import Foundation
import Cocoa
import WarpCore

@objc protocol QBEDocumentViewControllerDelegate: NSObjectProtocol {
	func documentView(_ view: QBEDocumentViewController, didSelectSearchable: QBESearchable?)
}

@objc class QBEDocumentViewController: NSViewController, NSToolbarItemValidation, QBETabletViewDelegate, QBEDocumentViewDelegate, QBEWorkspaceViewDelegate, QBEExportViewDelegate, QBEAlterTableViewDelegate {
	private enum State {
		case workspace
		case zoomed(controller: NSViewController, source: NSViewController, sourceView: NSView, sourceConstraints: [NSLayoutConstraint])
	}

	@IBOutlet var addTabletMenu: NSMenu!
	@IBOutlet var readdMenuItem: NSMenuItem!
	@IBOutlet var readdTabletMenu: NSMenu!
	@IBOutlet var workspaceView: QBEWorkspaceView!
	@IBOutlet var welcomeLabel: NSTextField!
	@IBOutlet var documentAreaView: NSView!

	@IBOutlet weak var delegate: QBEDocumentViewControllerDelegate? = nil
	private var documentView: QBEDocumentView!
	private var sentenceEditor: QBESentenceViewController? = nil

	private var state: State = .workspace
	
	var document: QBEDocument? { didSet {
		self.documentView?.removeAllTablets()
		if let d = document {
			for tablet in d.tablets {
				self.addTablet(tablet, undo: false, animated: false)
			}
			self.zoomToAll()
		}
	} }
	
	internal var locale: Language { get {
		return QBEAppDelegate.sharedInstance.locale ?? Language()
	} }

	private func zoom(to controller: QBETabletViewController, animated: Bool) {
		switch self.state {
		case .workspace:
			if let resizableController = controller.parent {
				if self.workspaceView.magnification < 1.0 {
					if animated {
						NSAnimationContext.runAnimationGroup({ (ac) -> Void in
							ac.duration = 0.3
							self.workspaceView.animator().magnify(toFit: controller.view.superview!.frame)
						}, completionHandler: nil)
					}
					else {
						self.workspaceView.magnify(toFit: controller.view.superview!.frame)
					}
					return
				}

				let selectedView = controller.view
				let sourceView = selectedView.superview!

				let savedConstraints = sourceView.constraints.filter { ctr -> Bool in
					if let fe = ctr.firstItem as? NSView, fe == selectedView {
						return true
					}

					if let se = ctr.secondItem as? NSView, se == selectedView {
						return true
					}

					return false
				}

				if animated {
					let tr = CATransition()
					tr.duration = 0.3
					tr.startProgress = 0.0
					tr.endProgress = 1.0
					tr.type = CATransitionType.fade
					tr.subtype = CATransitionSubtype.fromRight
					tr.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
					self.documentAreaView.layer?.add(tr, forKey: kCATransition)
				}

				controller.removeFromParent()
				selectedView.removeFromSuperview()
				selectedView.frame = self.view.bounds
				self.addChild(controller)
				self.documentAreaView.addSubview(selectedView)

				self.documentAreaView.addConstraints([
					NSLayoutConstraint(item: selectedView, attribute: .top, relatedBy: .equal, toItem: self.documentAreaView, attribute: .top, multiplier: 1.0, constant: 0.0),
					NSLayoutConstraint(item: selectedView, attribute: .bottom, relatedBy: .equal, toItem: self.documentAreaView, attribute: .bottom, multiplier: 1.0, constant: 0.0),
					NSLayoutConstraint(item: selectedView, attribute: .left, relatedBy: .equal, toItem: self.documentAreaView, attribute: .left, multiplier: 1.0, constant: 0.0),
					NSLayoutConstraint(item: selectedView, attribute: .right, relatedBy: .equal, toItem: self.documentAreaView, attribute: .right, multiplier: 1.0, constant: 0.0)
				])

				self.workspaceView.isHidden = true
				self.documentAreaView.layoutSubtreeIfNeeded()

				self.state = .zoomed(controller: controller, source: resizableController, sourceView: sourceView, sourceConstraints: savedConstraints)
			}

		case .zoomed(controller: _, source: _, sourceView: _, sourceConstraints: _):
			// Must zoom out first
			self.backToWorkspace(animated) {
				self.zoom(to: controller, animated: animated)
			}
			break
		}
	}

	@IBAction func zoomSelection(_ sender: NSObject) {
		if let selectedController = documentView.selectedTabletController {
			self.zoom(to: selectedController, animated: true)
		}
	}

	private func backToWorkspace(_ animated: Bool = true, completion: (() -> ())? = nil) {
		switch self.state {
		case .workspace:
			completion?()
			return

		case .zoomed(controller: let selectedController, source: let source, sourceView: let sourceView, sourceConstraints: let sourceConstraints):
			if animated {
				let tr = CATransition()
				tr.duration = 0.3
				tr.startProgress = 0.0
				tr.endProgress = 1.0
				tr.type = CATransitionType.fade
				tr.subtype = CATransitionSubtype.fromRight
				tr.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
				self.documentAreaView.layer?.add(tr, forKey: kCATransition)
			}

			let selectedView = selectedController.view
			selectedView.removeFromSuperview()
			selectedController.removeFromParent()
			source.addChild(selectedController)
			sourceView.addSubview(selectedView)
			sourceView.addConstraints(sourceConstraints)

			self.view.layoutSubtreeIfNeeded()
			self.documentView.resizeDocument()
			self.workspaceView.isHidden = false
			self.workspaceView.magnify(toFit: sourceView.frame)
			self.state = .workspace
			completion?()
		}
	}

	private func zoomToAll(_ animated: Bool = true, completion: (() -> ())? = nil) {
		switch self.state {
		case .workspace:
			// Not zoomed to a single tablet, zoom out to view all
			if let ab = self.documentView.boundsOfAllTablets {
				if animated {
					NSAnimationContext.runAnimationGroup({ (ac) -> Void in
						ac.duration = 0.3
						self.workspaceView.animator().magnify(toFit: ab)
					}, completionHandler: completion)
				}
				else {
					self.workspaceView.magnify(toFit: ab)
					completion?()
				}
			}

		default:
			completion?()
			return
		}
	}

	func tabletViewDidClose(_ view: QBETabletViewController) -> Bool {
		if let t = view.tablet {
			let force = self.view.window?.currentEvent?.modifierFlags.contains(.option) ?? false
			return removeTablet(t, undo: true, force: force)
		}
		return false
	}

	func tabletView(_ view: QBETabletViewController, exportObject: NSObject) {
		if let chain = exportObject as? QBEChain {
			self.receiveChain(chain, atLocation: nil, isDestination: false)
		}
	}

	func tabletViewDidChangeContents(_ view: QBETabletViewController) {
		documentView.resizeDocument()
		documentView.reloadData()
	}
	
	func tabletView(_ view: QBETabletViewController, didSelectConfigurable configurable: QBEConfigurable?, configureNow: Bool, delegate: QBESentenceViewDelegate?) {
		if self.documentView.selectedTablet != view.tablet {
			documentView.selectTablet(view.tablet, notifyDelegate: true)
		}

		if case .workspace = self.state {
			view.view.superview?.orderFront()
		}

		// Only show this tablet in the sentence editor if it really has become the selected tablet
		if self.documentView.selectedTablet == view.tablet {
			self.sentenceEditor?.startConfiguring(configurable, variant: .read, delegate: delegate)
		}

		if configureNow {
			self.sentenceEditor?.configure(self)
		}

		// When editing the sentence, all other commands should still go to the original tablet
		self.sentenceEditor?.nextResponder = view.responder
	}
	
	@objc func removeTablet(_ tablet: QBETablet) {
		removeTablet(tablet, undo: false, force: false)
	}
	
	@discardableResult func removeTablet(_ tablet: QBETablet, undo: Bool, force: Bool = false) -> Bool {
		assert(tablet.document == document, "tablet should belong to our document")

		// Who was dependent on this tablet?
		if let d = document {
			for otherTablet in d.tablets {
				if otherTablet == tablet {
					continue
				}

				for dep in otherTablet.arrows {
					if dep.from == tablet {
						if force {
							if let to = dep.to {
								// Recursively remove the dependent tablets first
								self.removeTablet(to, undo: undo, force: true)
							}
						}
						else {
							// TODO: automatically remove this dependency. For now just bail out
							NSAlert.showSimpleAlert("This item cannot be removed, because other items are still linked to it.".localized, infoText: "To remove the item, first remove any links to this item, then try to remove the table itself. Alternatively, if you hold the option key while removing the item, the linked items will be removed as well.".localized, style: .warning, window: self.view.window)
							return false
						}
					}
				}
			}
		}

		document?.removeTablet(tablet)
		self.sentenceEditor?.startConfiguring(nil, variant: .read, delegate: nil)
		documentView.removeTablet(tablet) {
			assertMainThread()

			self.backToWorkspace(true)
		
			for cvc in self.children {
				if let child = cvc as? QBEChainViewController {
					if child.chain?.tablet == tablet {
						child.removeFromParent()
					}
				}
			}
		
			self.view.window?.makeFirstResponder(self.documentView)
			self.updateView()

			/* If there are no tablets left in the currently visible rectangle, or there is only one tablet left, zoom
			back to the remaining tablet(s) */
			if (self.document?.tablets.count ?? 0) == 1 || self.documentView.visibleRect.intersection(self.documentView.boundsOfAllTablets ?? CGRect.zero).isEmpty {
				self.zoomToAll(true)
			}
			
			// Register undo operation. Do not retain the QBETablet but instead serialize, so all caches are properly destroyed.
			if undo {
				let data = NSKeyedArchiver.archivedData(withRootObject: tablet)
				
				if let um = self.undoManager {
					um.registerUndo(withTarget: self, selector: #selector(QBEDocumentViewController.addTabletFromArchivedData(_:)), object: data)
					um.setActionName(NSLocalizedString("Remove tablet", comment: ""))
				}
			}
		}
		return true
	}
	
	private var defaultTabletFrame: CGRect { get {
		let vr = self.workspaceView.documentVisibleRect
		let defaultWidth: CGFloat = max(350, min(800, vr.size.width * 0.382 * self.workspaceView.magnification))
		let defaultHeight: CGFloat = max(300, min(600, vr.size.height * 0.382 * self.workspaceView.magnification))
		
		// If this is not the first view, place it to the right of all other views
		if let ab = documentView.boundsOfAllTablets {
			return CGRect(x: ab.origin.x + ab.size.width + 25, y: ab.origin.y + ((ab.size.height - defaultHeight) / 2), width: defaultWidth, height: defaultHeight)
		}
		else {
			// If this is the first view, just center it in the visible rect
			return CGRect(x: vr.origin.x + (vr.size.width - defaultWidth) / 2, y: vr.origin.y + (vr.size.height - defaultHeight) / 2, width: defaultWidth, height: defaultHeight)
		}
	} }
	
	func addTablet(_ tablet: QBETablet, atLocation location: CGPoint?, undo: Bool) {
		// By default, tablets get a size that (when at 100% zoom) fills about 61% horizontally/vertically
		if tablet.frame == nil {
			tablet.frame = defaultTabletFrame
		}
		
		if let l = location {
			tablet.frame = tablet.frame!.centeredAt(l)
		}
		
		self.addTablet(tablet, undo: undo, animated: true)
	}
	
	@objc func addTabletFromArchivedData(_ data: Data) {
		if let t = NSKeyedUnarchiver.unarchiveObject(with: data) as? QBETablet {
			self.addTablet(t, undo: false, animated: true)
		}
	}
	
	@objc func addTablet(_ tablet: QBETablet, undo: Bool, animated: Bool, callback: ((QBETabletViewController) -> ())? = nil) {
		if let d = self.document {
			// Check if this tablet is also in the document
			if tablet.document != self.document {
				d.addTablet(tablet)
			}

			if tablet.frame == nil {
				tablet.frame = self.defaultTabletFrame
			}

			let vc = self.viewControllerForTablet(tablet)
			self.addChild(vc)

			self.documentView.addTablet(vc, animated: animated) {
				self.documentView.selectTablet(tablet)
				callback?(vc)
			}
			self.updateView()

			// Zoom if first tablet
			if d.tablets.count == 1 {
				self.zoom(to: vc, animated: true)
			}
			else {
				self.backToWorkspace(true) {
					self.workspaceView.magnify(toFit: vc.view.superview!.frame)
				}
			}
		}
	}

	fileprivate func viewControllerForTablet(_ tablet: QBETablet) -> QBETabletViewController {
		let tabletController = QBEFactory.sharedInstance.viewControllerForTablet(tablet, storyboard: self.storyboard!)
		tabletController.delegate = self
		return tabletController
	}
	
	fileprivate func updateView() {
		self.workspaceView.hasHorizontalScroller = (self.document?.tablets.count ?? 0) > 0
		self.workspaceView.hasVerticalScroller = (self.document?.tablets.count ?? 0) > 0
		self.welcomeLabel.isHidden = (self.document?.tablets.count ?? 0) != 0

		// Apparently, starting in El Capitan, the label does not repaint itself automatically and stays in view after setting hidden=true
		self.welcomeLabel.needsDisplay = true
		self.view.setNeedsDisplay(self.view.bounds)
	}

	override func viewWillLayout() {
		self.documentView.resizeDocument()
		super.viewWillLayout()
	}

	@IBAction func selectPreviousTablet(_ sender: NSObject) {
		cycleTablets(-1)
	}

	@IBAction func selectNextTablet(_ sender: NSObject) {
		cycleTablets(1)
	}

	private func cycleTablets(_ offset: Int) {
		if let d = self.document, d.tablets.count > 0 {
			let currentTablet = documentView.selectedTablet ?? d.tablets[0]
            if let index = d.tablets.firstIndex(of: currentTablet) {
				let nextIndex = (index+offset) % d.tablets.count
				let nextTablet = d.tablets[nextIndex]
				self.documentView.selectTablet(nextTablet)
				if let selectedController = documentView.selectedTabletController, let selectedView = selectedController.view.superview {
					if case .zoomed(controller: _, source: _, sourceView: _, sourceConstraints: _) = self.state {
						self.zoom(to: selectedController, animated: true)
					}
					else {
						self.workspaceView.animator().magnify(toFit: selectedView.frame)
					}
				}
			}
		}
	}

	@objc func exportView(_ view: QBEExportViewController, finishedExportingTo: URL) {
		let ext = finishedExportingTo.pathExtension
		if QBEFactory.sharedInstance.fileTypesForReading.contains(ext) {
			self.addTabletFromURL(finishedExportingTo)
		}
	}

	@IBAction func zoomToAll(_ sender: NSObject) {
		zoomToAll(true, completion: nil)
	}

	@IBAction func pasteAsPlainText(_ sender: AnyObject) {
		let pboard = NSPasteboard.general

		if let data = pboard.string(forType: NSPasteboard.PasteboardType.string) {
			let note = QBENoteTablet()
			note.note.text = NSAttributedString(string: data)
			self.addTablet(note, undo: true, animated: true)
		}
	}

	@IBAction func paste(_ sender: NSObject) {
		// Pasting a step?
		let pboard = NSPasteboard.general
		if let data = pboard.data(forType: QBEStep.dragType) {
			if let step = NSKeyedUnarchiver.unarchiveObject(with: data) as? QBEStep {
				self.addTablet(QBEChainTablet(chain: QBEChain(head: step)), undo: true, animated: true)
			}
		}
		else {
			// No? Maybe we're pasting TSV/CSV data...
			var data = pboard.string(forType: NSPasteboard.PasteboardType.string)
			if data == nil {
				data = pboard.string(forType: NSPasteboard.PasteboardType.tabularText)
			}
			
			if let tsvString = data {
				var data: [Tuple] = []
				var headerRow: Tuple? = nil
				let rows = tsvString.components(separatedBy: "\r")
				for row in rows {
					var rowValues: [Value] = []
					
					let cells = row.components(separatedBy: "\t")
					for cell in cells {
						rowValues.append(locale.valueForLocalString(cell))
					}
					
					if headerRow == nil {
						headerRow = rowValues
					}
					else {
						data.append(rowValues)
					}
				}
				
				if headerRow != nil {
					let cns = Set(headerRow!.map({return Column($0.stringValue ?? "")}))
					let cols = OrderedSet(cns)
					let raster = Raster(data: data, columns: cols, readOnly: false)
					let s = QBERasterStep(raster: raster)
					let tablet = QBEChainTablet(chain: QBEChain(head: s))
					addTablet(tablet, undo: true, animated: true)
				}
			}
		}
	}
	
	@IBAction func addButtonClicked(_ sender: NSView) {
		// Populate the 'copy of source step' sub menu
		class QBETemplateAdder: NSObject {
			var templateSteps: [QBEStep] = []
			var documentView: QBEDocumentViewController

			init(documentView: QBEDocumentViewController) {
				self.documentView = documentView
			}

			@objc func readdStep(_ sender: NSMenuItem) {
				if sender.tag >= 0 && sender.tag < templateSteps.count {
					let templateStep = templateSteps[sender.tag]
					let templateDataset = NSKeyedArchiver.archivedData(withRootObject: templateStep)
					let newStep = NSKeyedUnarchiver.unarchiveObject(with: templateDataset) as? QBEStep
					let tablet = QBEChainTablet(chain: QBEChain(head: newStep))
					self.documentView.addTablet(tablet, undo: true, animated: true) { _ in
						self.documentView.sentenceEditor?.configure(self.documentView)
					}
				}
			}
		}

		let adder = QBETemplateAdder(documentView: self)
		readdTabletMenu.removeAllItems()
		if let d = self.document {
			// Loop over all chain tablets and add menu items to re-add the starting step from each chain
			for tablet in d.tablets {
				if let chainTablet = tablet as? QBEChainTablet {
					for step in chainTablet.chain.steps {
						if step.previous == nil {
							// This is a source step
							let item = NSMenuItem(title: step.sentence(self.locale, variant: .read).stringValue, action: #selector(QBETemplateAdder.readdStep(_:)), keyEquivalent: "")
							item.isEnabled = true
							item.tag = adder.templateSteps.count
							item.target = adder
							adder.templateSteps.append(step)
							readdTabletMenu.addItem(item)
						}
					}
				}
			}
		}

		// The re-add menu item is hidden when the menu is opened from the context menu
		readdMenuItem.isHidden = false
		readdMenuItem.isEnabled = !adder.templateSteps.isEmpty
		NSMenu.popUpContextMenu(self.addTabletMenu, with: NSApplication.shared.currentEvent!, for: self.view)
		readdMenuItem.isEnabled = false
		readdMenuItem.isHidden = true
	}

	func workspaceView(_ view: QBEWorkspaceView, didReceiveStep step: QBEStep, atLocation location: CGPoint) {
		assertMainThread()

		let chain = QBEChain(head: step)
		let tablet = QBEChainTablet(chain: chain)
		self.addTablet(tablet, atLocation: location, undo: true)
	}

	func receiveChain(_ chain: QBEChain, atLocation: CGPoint?, isDestination: Bool) {
		assertMainThread()

		if chain.head != nil {
			let ac = QBEDropChainAction(chain: chain, documentView: self, location: atLocation)
			ac.present(isDestination)
		}
	}

	/** Called when an outlet is dropped onto the workspace itself (e.g. an empty spot). */
	func workspaceView(_ view: QBEWorkspaceView, didReceiveChain chain: QBEChain, atLocation: CGPoint) {
		receiveChain(chain, atLocation: atLocation, isDestination: true)
	}

	/** Called when a set of columns was dropped onto the document. */
	func workspaceView(_ view: QBEWorkspaceView, didReceiveColumnSet colset: OrderedSet<Column>, fromDatasetViewController dc: QBEDatasetViewController) {
		let action = QBEDropColumnsAction(columns: colset, dataViewController: dc, documentViewController: self)
		action.present()
	}
	
	func workspaceView(_ view: QBEWorkspaceView, didReceiveFiles files: [URL], atLocation: CGPoint) {
		// Gather file paths
		var tabletsAdded: [QBETablet] = []
		
		for file in files {
			if let t = addTabletFromURL(file) {
				tabletsAdded.append(t)
			}
		}
		
		// Zoom to all newly added tablets
		var allRect = CGRect.zero
		for tablet in tabletsAdded {
			if let f = tablet.frame {
				allRect = allRect.union(f)
			}
		}
		self.workspaceView.magnify(toFit: allRect)
	}
	
	func documentView(_ view: QBEDocumentView, didSelectArrow arrow: QBETabletArrow?) {
		if let a = arrow, let fromTablet = a.to {
			findAndSelectArrow(a, inTablet: fromTablet)
		}
	}

	func tabletViewControllerForTablet(_ tablet: QBETablet) -> QBETabletViewController? {
		for cvc in self.children {
			if let child = cvc as? QBETabletViewController {
				if child.tablet == tablet {
					return child
				}
			}
		}
		return nil
	}
	
	func findAndSelectArrow(_ arrow: QBETabletArrow, inTablet tablet: QBETablet) {
		if let child = self.tabletViewControllerForTablet(tablet) {
			documentView.selectTablet(tablet)
			child.view.superview?.orderFront()
			didSelectTablet(child.tablet)
			child.selectArrow(arrow)
		}
	}
	
	private func didSelectTablet(_ tablet: QBETablet?) {
		self.sentenceEditor?.startConfiguring(nil, variant: .neutral, delegate: nil)

		for childController in self.children {
			if let cvc = childController as? QBETabletViewController {
				if cvc.tablet != tablet {
					cvc.tabletWasDeselected()
				}
				else {
					cvc.tabletWasSelected()
					cvc.view.orderFront()
					if let searchable = cvc as? QBESearchable {
						self.delegate?.documentView(self, didSelectSearchable: searchable)
					}
					else {
						self.delegate?.documentView(self, didSelectSearchable: nil)
					}
				}
			}
		}

		if tablet == nil {
			self.delegate?.documentView(self, didSelectSearchable: nil)
		}

		self.view.window?.update()
		self.view.window?.toolbar?.validateVisibleItems()
	}
	
	func documentView(_ view: QBEDocumentView, didSelectTablet tablet: QBETablet?) {
		didSelectTablet(tablet)
	}

	func documentView(_ view: QBEDocumentView, wantsZoomTo controller: QBETabletViewController) {
		self.zoom(to: controller, animated: true)
		documentView.reloadData()
	}
	
	@discardableResult private func addTabletFromURL(_ url: URL, atLocation: CGPoint? = nil) -> QBETablet? {
		assertMainThread()

		if let sourceStep = QBEFactory.sharedInstance.stepForReadingFile(url) {
			let tablet = QBEChainTablet(chain: QBEChain(head: sourceStep))
			self.addTablet(tablet, atLocation: atLocation, undo: true)
			return tablet
		}
		else {
			// This may be a warp document - open separately
			let p = url.path
			NSWorkspace.shared.openFile(p)
		}

		return nil
	}

	func alterTableView(_ view: QBEAlterTableViewController, didAlterTable mutableDataset: MutableDataset?) {
		let job = Job(.userInitiated)
		mutableDataset?.data(job) {result in
			switch result {
			case .success(let data):
				data.raster(job) { result in
					switch result {
					case .success(let raster):
						asyncMain {
							let tablet = QBEChainTablet(chain: QBEChain(head: QBERasterStep(raster: raster)))
							self.addTablet(tablet, atLocation: nil, undo: true)
						}

					case .failure(let e):
						asyncMain {
							NSAlert.showSimpleAlert(NSLocalizedString("Could not add table", comment: ""), infoText: e, style: .critical, window: self.view.window)
						}
					}
				}

			case .failure(let e):
				asyncMain {
					NSAlert.showSimpleAlert(NSLocalizedString("Could not add table", comment: ""), infoText: e, style: .critical, window: self.view.window)
				}
			}
		}
	}

	@IBAction func addNoteTablet(_ sender: NSObject) {
		let tablet = QBENoteTablet()
		self.addTablet(tablet, undo: true, animated: true)
	}

	@IBAction func addRasterTablet(_ sender: NSObject) {
		let keyColumn = Column("id".localized)
		let raster = Raster(data: [], columns: [keyColumn], readOnly: false)
		let chain = QBEChain(head: QBERasterStep(raster: raster))
		let tablet = QBEChainTablet(chain: chain)
		self.addTablet(tablet, undo: true, animated: true) { tabletViewController in
			tabletViewController.startEditingWithIdentifier([keyColumn])
		}
	}

	@IBAction func addSequencerTablet(_ sender: NSObject) {
		let chain = QBEChain(head: QBESequencerStep())
		let tablet = QBEChainTablet(chain: chain)
		self.addTablet(tablet, undo: true, animated: true)
	}
	
	@IBAction func addTabletFromFile(_ sender: NSObject) {
		let no = NSOpenPanel()
		no.canChooseFiles = true
		no.allowsMultipleSelection = true
		no.allowedFileTypes?.append("public.text")
		//	= NSArray(arrayLiteral: "public.text") // QBEFactory.sharedInstance.fileTypesForReading
		
		no.beginSheetModal(for: self.view.window!, completionHandler: { result in
			if result == NSApplication.ModalResponse.OK {
				for url in no.urls {
					self.addTabletFromURL(url)
				}
			}
		})
	}

	@IBAction func addTabletFromWeb(_ sender: NSObject) {
		self.addTablet(QBEChainTablet(chain: QBEChain(head: QBEHTTPStep())), undo: true, animated: true) { _ in
			self.sentenceEditor?.configure(self)
		}
	}
	
	@IBAction func addTabletFromMySQL(_ sender: NSObject) {
		let s = QBEMySQLSourceStep(host: "127.0.0.1", port: 3306, user: "root", database: nil, tableName: nil)
		self.addTablet(QBEChainTablet(chain: QBEChain(head: s)), undo: true, animated: true) { _ in
			self.sentenceEditor?.configure(self)
		}
	}
	
	@IBAction func addTabletFromPostgres(_ sender: NSObject) {
		let s = QBEPostgresSourceStep(host: "127.0.0.1", port: 5432, user: "postgres", database: "postgres", schemaName: "public", tableName: "")
		self.addTablet(QBEChainTablet(chain: QBEChain(head: s)), undo: true, animated: true) { _ in
			self.sentenceEditor?.configure(self)
		}
	}
	
	override func prepare(for segue: NSStoryboardSegue, sender: Any?) {
		if segue.identifier == "sentence" {
			self.sentenceEditor = segue.destinationController as? QBESentenceViewController
			self.sentenceEditor?.view.translatesAutoresizingMaskIntoConstraints = false
		}
	}

	func validate(_ item: NSValidatedUserInterfaceItem) -> Bool {
		return self.validateUserInterfaceItem(item)
	}

	@objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
			return validateSelector(item.action!)
	}

	@objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
		return validateSelector(item.action!)
	}

	@IBAction func goBackToWorkspace(_ sender: Any) {
		self.backToWorkspace(true, completion: nil)
	}

	private func validateSelector(_ selector: Selector) -> Bool {
		if selector == #selector(QBEDocumentViewController.selectNextTablet(_:)) { return (self.document?.tablets.count ?? 0) > 0 }
		if selector == #selector(QBEDocumentViewController.selectPreviousTablet(_:)) { return (self.document?.tablets.count ?? 0) > 0 }
		if selector == #selector(QBEDocumentViewController.addButtonClicked(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addSequencerTablet(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addRasterTablet(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addNoteTablet(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addTabletFromWeb(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addTabletFromFile(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addTabletFromMySQL(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.addTabletFromPostgres(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.zoomSelection(_:)) {
			switch self.state {
			case .workspace:
				return self.documentView.selectedTablet != nil
			default:
				return false
			}
		}
		if selector == #selector(QBEDocumentViewController.zoomToAll(_:) as (QBEDocumentViewController) -> (NSObject) -> ()) {
			switch self.state {
			case .workspace:
				return self.documentView.boundsOfAllTablets != nil && self.workspaceView.magnification >= 1.0
			default:
				return false
			}
		}
		if selector == #selector(QBEDocumentViewController.goBackToWorkspace(_:) as (QBEDocumentViewController) -> (NSObject) -> ()) {
			switch self.state {
			case .workspace:
				return false
			default:
				return true
			}
		}
		if selector == #selector(NSText.delete(_:)) { return true }
		if selector == #selector(QBEDocumentViewController.paste(_:)) {
			let pboard = NSPasteboard.general
			if pboard.data(forType: QBEStep.dragType) != nil || pboard.data(forType: NSPasteboard.PasteboardType.string) != nil || pboard.data(forType: NSPasteboard.PasteboardType.tabularText) != nil {
				return true
			}
		}
		if selector == #selector(QBEDocumentViewController.pasteAsPlainText(_:)) {
			let pboard = NSPasteboard.general
			return pboard.data(forType: NSPasteboard.PasteboardType.string) != nil
		}
		return false
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		self.zoomToAll(false)
	}
	
	override func viewDidLoad() {
		let initialDocumentSize = self.workspaceView.bounds
		
		documentView = QBEDocumentView(frame: initialDocumentSize)
		documentView.delegate = self
		self.workspaceView.delegate = self
		self.workspaceView.documentView = documentView
		documentView.resizeDocument()
	}
}

private class QBEDropChainAction: NSObject {
	private var chain: QBEChain
	private var documentView: QBEDocumentViewController
	private var location: CGPoint?
	private var relatedSteps: [QBERelatedStep] = []

	init(chain: QBEChain, documentView: QBEDocumentViewController, location: CGPoint?) {
		self.chain = chain
		self.documentView = documentView
		self.location = location
	}

	@objc func addClone(_ sender: NSObject) {
		let tablet = QBEChainTablet(chain: QBEChain(head: QBECloneStep(chain: chain)))
		self.documentView.addTablet(tablet, atLocation: location, undo: true)
	}

	@objc func addChart(_ sender: NSObject) {
		if let sourceTablet = chain.tablet as? QBEChainTablet {
			let job = Job(.userInitiated)
			let jobProgressView = QBEJobViewController(job: job, description: "Analyzing data...".localized)!
			self.documentView.presentAsSheet(jobProgressView)

			sourceTablet.chain.head?.exampleDataset(job, maxInputRows: 1000, maxOutputRows: 1, callback: { (result) -> () in
				switch result {
				case .success(let data):
					data.columns(job) { result in
						switch result {
						case .success(let columns):
							asyncMain {
								jobProgressView.dismiss(sender)
								if let first = Array(columns).first, let last = Array(columns).last, columns.count > 1 {
									let tablet = QBEChartTablet(source: sourceTablet, type: .Bar, xExpression: Sibling(first), yExpression: Sibling(last))
									self.documentView.addTablet(tablet, atLocation: self.location, undo: true)
								}
								else {
									asyncMain {
										NSAlert.showSimpleAlert("Could not create a chart of this data".localized, infoText: "In order to be able to create a chart, the data set must contain at least two columns.".localized, style: .critical, window: self.documentView.view.window)
									}
								}
							}

						case .failure(let e):
							asyncMain {
								NSAlert.showSimpleAlert("Could not create a chart of this data".localized, infoText: e, style: .critical, window: self.documentView.view.window)
							}
						}
					}

				case .failure(let e):
					asyncMain {
						NSAlert.showSimpleAlert("Could not create a chart of this data".localized, infoText: e, style: .critical, window: self.documentView.view.window)
					}
				}
			})
		}
	}

	@objc func addMap(_ sender: NSObject) {
		if let sourceTablet = chain.tablet as? QBEChainTablet {
			let job = Job(.userInitiated)
			let jobProgressView = QBEJobViewController(job: job, description: "Analyzing data...".localized)!
			self.documentView.presentAsSheet(jobProgressView)

			sourceTablet.chain.head?.exampleDataset(job, maxInputRows: 1000, maxOutputRows: 1, callback: { (result) -> () in
				switch result {
				case .success(let data):
					data.columns(job) { result in
						switch result {
						case .success(let columns):
							asyncMain {
								jobProgressView.dismiss(sender)
								let tablet = QBEMapTablet(source: sourceTablet,columns: columns)
								self.documentView.addTablet(tablet, atLocation: self.location, undo: true)
							}

						case .failure(let e):
							asyncMain {
								NSAlert.showSimpleAlert("Could not create a map of this data".localized, infoText: e, style: .critical, window: self.documentView.view.window)
							}
						}
					}

				case .failure(let e):
					asyncMain {
						NSAlert.showSimpleAlert("Could not create a map of this data".localized, infoText: e, style: .critical, window: self.documentView.view.window)
					}
				}
			})
		}
	}


	@objc func addCopy(_ sender: NSObject) {
		let job = Job(.userInitiated)
		QBEAppDelegate.sharedInstance.jobsManager.addJob(job, description: NSLocalizedString("Create copy of data here", comment: ""))
		chain.head?.fullDataset(job) { result in
			switch result {
			case .success(let fd):
				fd.raster(job) { result in
					switch result {
					case .success(let raster):
						asyncMain {
							let tablet = QBEChainTablet(chain: QBEChain(head: QBERasterStep(raster: raster)))
							self.documentView.addTablet(tablet, atLocation: self.location, undo: true)
						}
					case .failure(let e):
						asyncMain {
							NSAlert.showSimpleAlert(NSLocalizedString("Could not copy the data",comment: ""), infoText: e, style: .critical, window: self.documentView.view.window)
						}
					}
				}
			case .failure(let e):
				asyncMain {
					NSAlert.showSimpleAlert(NSLocalizedString("Could not copy the data",comment: ""), infoText: e, style: .critical, window: self.documentView.view.window)
				}
			}
		}
	}

	@objc func exportFile(_ sender: NSObject) {
		var exts: [String: String] = [:]
		for ext in QBEFactory.sharedInstance.fileExtensionsForWriting {
			let writer = QBEFactory.sharedInstance.fileWriterForType(ext)!
			exts[ext] = writer.explain(ext, locale: self.documentView.locale)
		}

		let ns = QBEFilePanel(allowedFileTypes: exts)
		ns.askForSaveFile(self.documentView.view.window!) { (urlFallible) -> () in
			urlFallible.maybe { (url) in
				self.exportToFile(url)
			}
		}
	}

	private func exportToFile(_ url: URL) {
		let writerType: QBEFileWriter.Type
		let ext = url.pathExtension
		writerType = QBEFactory.sharedInstance.fileWriterForType(ext) ?? QBECSVWriter.self

		let title = chain.tablet?.displayName ?? NSLocalizedString("Warp data", comment: "")
		let s = QBEExportStep(previous: chain.head!, writer: writerType.init(locale: self.documentView.locale, title: title), file: QBEFileReference.absolute(url))

		if let editorController = self.documentView.storyboard?.instantiateController(withIdentifier: "exportEditor") as? QBEExportViewController {
			editorController.step = s
			editorController.delegate = self.documentView
			editorController.locale = self.documentView.locale
			self.documentView.presentAsSheet(editorController)
		}
	}

	@objc func saveToWarehouse(_ sender: NSObject) {
		let job = Job(.userInitiated)

		let stepTypes = QBEFactory.sharedInstance.dataWarehouseSteps
		if let s = sender as? NSMenuItem, s.tag >= 0 && s.tag <= stepTypes.count, let sourceStep = chain.head {
			let stepType = stepTypes[s.tag]

			let uploadView = self.documentView.storyboard?.instantiateController(withIdentifier: "uploadDataset") as! QBEUploadViewController
			let targetStep = stepType.init()

			uploadView.afterSuccessfulUpload = {
				// Add the written data as tablet to the document view
				asyncMain {
					let tablet = QBEChainTablet(chain: QBEChain(head: targetStep))
					self.documentView.addTablet(tablet, atLocation: self.location, undo: true)
				}
			}

			uploadView.setup(job: job, source: sourceStep, target: targetStep) { result in
				asyncMain {
					switch result {
					case .success():
						self.documentView.presentAsSheet(uploadView)

					case .failure(let e):
						NSAlert.showSimpleAlert("Cannot upload data".localized, infoText: e, style: .warning, window: self.documentView.view.window)
					}
				}
			}
		}
	}

	@objc func selectRelatedStep(_ sender: NSObject) {
		assertMainThread()

		if let mi = sender as? NSMenuItem, mi.tag < self.relatedSteps.count, let myHead = self.chain.head {
			let related = self.relatedSteps[mi.tag]

			switch related {
			case .joinable(step: let joinableStep, type: let type, condition: let expression):
				let joinableChain = QBEChain(head: joinableStep)
				let tablet = QBEChainTablet(chain: joinableChain)
				self.documentView.addTablet(tablet, undo: true, animated: true)

				self.documentView.updateView()

				asyncMain {
					let joinStep = QBEJoinStep(previous: myHead)
					joinStep.condition = expression
					joinStep.joinType = type
					joinStep.right = joinableChain

					if let myTablet = self.chain.tablet, let vc = self.documentView.viewControllerForTablet(myTablet) as? QBEChainTabletViewController {
						self.chain.head = joinStep
						vc.chainViewController?.currentStep = joinStep
						vc.chainViewController?.stepsChanged()
						asyncMain {
							let arrows = myTablet.arrows.filter { return $0.from == tablet }
							if let arrow = arrows.first {
								self.documentView.findAndSelectArrow(arrow, inTablet: myTablet)
							}
						}
					}
				}
			}
		}
	}

	/** Present the menu with actions to perform with the chain. When `atDestination` is true, the menu uses wording that
	is appropriate when the menu is shown at the location of the drop. When it is false, wording is used that fits when
	the menu is presented at the source. */
	func present(_ atDestination: Bool) {
		let menu = NSMenu()
		menu.autoenablesItems = false

		let cloneItem = NSMenuItem(title: (atDestination ? "Create linked clone of data here" : "Create a linked clone of data").localized, action: #selector(QBEDropChainAction.addClone(_:)), keyEquivalent: "")
		cloneItem.target = self
		menu.addItem(cloneItem)

		if self.chain.tablet is QBEChainTablet {
			let chartItem = NSMenuItem(title: (atDestination ? "Create chart of data here" : "Create a chart from the data").localized, action: #selector(QBEDropChainAction.addChart(_:)), keyEquivalent: "")
			chartItem.target = self
			menu.addItem(chartItem)

			let mapItem = NSMenuItem(title: (atDestination ? "Create map of data here" : "Create a map from the data").localized, action: #selector(QBEDropChainAction.addMap(_:)), keyEquivalent: "")
			mapItem.target = self
			menu.addItem(mapItem)
		}

		let copyItem = NSMenuItem(title: (atDestination ? "Create copy of data here" : "Create a copy of the data").localized, action: #selector(QBEDropChainAction.addCopy(_:)), keyEquivalent: "")
		copyItem.target = self
		menu.addItem(copyItem)

		menu.addItem(NSMenuItem.separator())

		let stepTypes = QBEFactory.sharedInstance.dataWarehouseSteps

		for i in 0..<stepTypes.count {
			let stepType = stepTypes[i]
			if let name = QBEFactory.sharedInstance.dataWarehouseStepNames[stepType.className()] {
				let saveItem = NSMenuItem(title: String(format: "Upload data to %@...".localized, name), action: #selector(QBEDropChainAction.saveToWarehouse(_:)), keyEquivalent: "")
				saveItem.target = self
				saveItem.tag = i
				menu.addItem(saveItem)
			}
		}

		menu.addItem(NSMenuItem.separator())
		let exportFileItem = NSMenuItem(title: "Export data to file...".localized, action: #selector(QBEDropChainAction.exportFile(_:)), keyEquivalent: "")
		exportFileItem.target = self
		menu.addItem(exportFileItem)

		menu.addItem(NSMenuItem.separator())

		// Related data sets
		let relatedMenu = NSMenu()
		let loadingItem = NSMenuItem(title: "Loading...".localized, action: nil, keyEquivalent: "")
		loadingItem.isEnabled = false
		relatedMenu.addItem(loadingItem)

		// Populate related data sets menu
		let job = Job(.background)
		job.async { [weak self] in
			if let s = self?.chain.head {
				s.related(job: job) { result in
					asyncMain {
						relatedMenu.removeAllItems()
						switch result {
						case .success(let relatedSteps):
							if let strongSelf = self {
								strongSelf.relatedSteps = relatedSteps

								if relatedSteps.isEmpty {
									let loadingItem = NSMenuItem(title: "(No related data sets found)".localized, action: nil, keyEquivalent: "")
									loadingItem.isEnabled = false
									relatedMenu.addItem(loadingItem)
									return
								}

								for (idx, related) in relatedSteps.enumerated() {
									switch related {
									case .joinable(step: let joinableStep, type: _, condition: _):
										let relatedStepItem = NSMenuItem(title: joinableStep.explain(strongSelf.documentView.locale), action: #selector(strongSelf.selectRelatedStep(_:)), keyEquivalent: "")
										relatedStepItem.tag = idx
										relatedStepItem.target = strongSelf
										relatedStepItem.isEnabled = true
										relatedMenu.addItem(relatedStepItem)
									}
								}
							}

						case .failure(let e):
							let loadingItem = NSMenuItem(title: String(format: "(No related data sets found: %@)".localized, e), action: nil, keyEquivalent: "")
							loadingItem.isEnabled = false
							relatedMenu.addItem(loadingItem)
						}
					}
				}
			}
			else {
				asyncMain {
					relatedMenu.removeAllItems()
					let loadingItem = NSMenuItem(title: "(No related data sets found)".localized, action: nil, keyEquivalent: "")
					loadingItem.isEnabled = false
					relatedMenu.addItem(loadingItem)
				}
			}
		}

		let relatedItem = NSMenuItem(title: "Related data sets".localized, action: nil, keyEquivalent: "")
		relatedItem.submenu = relatedMenu
		menu.addItem(relatedItem)

		NSMenu.popUpContextMenu(menu, with: NSApplication.shared.currentEvent!, for: self.documentView.view)
	}
}

/** Action that handles dropping a set of columns on the document. Usually the columns come from another data view / chain
controller. */
private class QBEDropColumnsAction: NSObject {
	let columns: OrderedSet<Column>
	let documentViewController: QBEDocumentViewController
	let dataViewController: QBEDatasetViewController

	init(columns: OrderedSet<Column>, dataViewController: QBEDatasetViewController, documentViewController: QBEDocumentViewController) {
		self.columns = columns
		self.dataViewController = dataViewController
		self.documentViewController = documentViewController
	}

	/** Add a tablet to the document containing a chain that calculates the histogram of this column (unique values and
	their occurrence count). */
	@objc private func addHistogram(_ sender: NSObject) {
		if columns.count == 1 {
			if let sourceChainController = dataViewController.parent as? QBEChainViewController, let sourceChain = sourceChainController.chain {
				let countColumn = Column("Count".localized)
				let cloneStep = QBECloneStep(chain: sourceChain)
				let histogramStep = QBEPivotStep()
				histogramStep.previous = cloneStep
				histogramStep.rows = columns
				histogramStep.aggregates = [Aggregation(map: Sibling(columns.first!), reduce: .countAll, targetColumn: countColumn)]
				let sortStep = QBESortStep(previous: histogramStep, orders: [Order(expression: Sibling(countColumn), ascending: false, numeric: true)])

				let histogramChain = QBEChain(head: sortStep)
				let histogramTablet = QBEChainTablet(chain: histogramChain)

				self.documentViewController.addTablet(histogramTablet, atLocation: nil, undo: true)
			}
		}
	}

	/** Add a tablet to the document containing a raster table containing all unique values in the original column. This
	tablet is then joined to the original table. */
	@objc private func addLookupTable(_ sender: NSObject) {
		if columns.count == 1 {
			if let sourceChainController = dataViewController.parent as? QBEChainViewController, let step = sourceChainController.chain?.head {
				let job = Job(.userInitiated)
				let jobProgressView = QBEJobViewController(job: job, description: String(format: NSLocalizedString("Analyzing %d column(s)...", comment: ""), columns.count))!
				self.documentViewController.presentAsSheet(jobProgressView)

				step.fullDataset(job) { result in
					switch result {
					case .success(let data):
						data.unique(Sibling(self.columns.first!), job: job) { result in
							switch result {
							case .success(let uniqueValues):
								let rows = uniqueValues.map({ item in return [item] })
								let raster = Raster(data: rows, columns: [self.columns.first!], readOnly: false)
								let chain = QBEChain(head: QBERasterStep(raster: raster))
								let tablet = QBEChainTablet(chain: chain)
								asyncMain {
									jobProgressView.dismiss(nil)
									self.documentViewController.addTablet(tablet, atLocation: nil, undo: true)

									let joinStep = QBEJoinStep(previous: nil)
									joinStep.joinType = JoinType.leftJoin
									joinStep.condition = Comparison(first: Sibling(self.columns.first!), second: Foreign(self.columns.first!), type: .equal)
									joinStep.right = chain
									sourceChainController.chain?.insertStep(joinStep, afterStep: sourceChainController.chain?.head)
									sourceChainController.currentStep = joinStep
								}

							case .failure(_):
								break
							}

						}

					case .failure(_):
						break
					}
				}
			}
		}
	}

	func present() {
		let menu = NSMenu()
		menu.autoenablesItems = false

		if columns.count == 1 {
			if let sourceChainController = dataViewController.parent as? QBEChainViewController, sourceChainController.chain?.head != nil {
				let item = NSMenuItem(title: "Create a look-up table for this column".localized, action: #selector(QBEDropColumnsAction.addLookupTable(_:)), keyEquivalent: "")
				item.target = self
				menu.addItem(item)

				let histogramItem = NSMenuItem(title: "Add a histogram of this column".localized, action: #selector(QBEDropColumnsAction.addHistogram(_:)), keyEquivalent: "")
				histogramItem.target = self
				menu.addItem(histogramItem)
			}
		}
		else {
			// Do something with more than one column (multijoin)
		}

		NSMenu.popUpContextMenu(menu, with: NSApplication.shared.currentEvent!, for: self.documentViewController.view)
	}
}
