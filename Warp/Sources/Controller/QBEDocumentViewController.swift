import Foundation
import Cocoa
import WarpCore

@objc class QBEDocumentViewController: NSViewController, QBEChainViewDelegate, QBEDocumentViewDelegate, QBEWorkspaceViewDelegate, QBEExportViewDelegate, QBEAlterTableViewDelegate {
	private var documentView: QBEDocumentView!
	private var sentenceEditor: QBESentenceViewController? = nil
	@IBOutlet var addTabletMenu: NSMenu!
	@IBOutlet var readdMenuItem: NSMenuItem!
	@IBOutlet var readdTabletMenu: NSMenu!
	@IBOutlet var workspaceView: QBEWorkspaceView!
	@IBOutlet var welcomeLabel: NSTextField!
	@IBOutlet var documentAreaView: NSView!
	private var zoomedView: (NSView, CGRect)? = nil
	
	var document: QBEDocument? { didSet {
		self.documentView?.removeAllTablets()
		if let d = document {
			for tablet in d.tablets {
				self.addTablet(tablet, undo: false, animated: false)
			}
			self.zoomToAll()
		}
	} }
	
	internal var locale: QBELocale { get {
		return QBEAppDelegate.sharedInstance.locale ?? QBELocale()
	} }
	
	func chainViewDidClose(view: QBEChainViewController) -> Bool {
		if let t = view.chain?.tablet {
			return removeTablet(t, undo: true)
		}
		return false
	}
	
	func chainViewDidChangeChain(view: QBEChainViewController) {
		if workspaceView.magnifiedView == nil {
			documentView.resizeDocument()
		}
		documentView.reloadData()
	}
	
	func chainView(view: QBEChainViewController, configureStep: QBEStep?, delegate: QBESentenceViewDelegate) {
		if let ch = view.chain {
			if let tablet = ch.tablet {
				for cvc in self.childViewControllers {
					if let child = cvc as? QBEChainViewController {
						if child.chain?.tablet == tablet {
							documentView.selectTablet(tablet, notifyDelegate: false)
							child.view.superview?.orderFront()

							// Only show this tablet in the sentence editor if it really has become the selected tablet
							if self.documentView.selectedTablet == tablet {
								self.sentenceEditor?.configure(configureStep, variant: .Read, delegate: delegate)
							}
						}
					}
				}
			}
		}
	}
	
	@objc func removeTablet(tablet: QBETablet) {
		removeTablet(tablet, undo: false)
	}
	
	func removeTablet(tablet: QBETablet, undo: Bool) -> Bool {
		assert(tablet.document == document, "tablet should belong to our document")

		// Who was dependent on this tablet?
		if let d = document {
			for otherTablet in d.tablets {
				if otherTablet == tablet {
					continue
				}

				for dep in otherTablet.chain.dependencies {
					if dep.dependsOn == tablet.chain {
						// TODO: automatically remove this dependency. For now just bail out
						NSAlert.showSimpleAlert(NSLocalizedString("This table cannot be removed, because other items are still linked to it.", comment: ""), infoText: NSLocalizedString("To remove the table, first remove any links to this table, then try to remove the table itself.", comment: ""), style: .WarningAlertStyle, window: self.view.window)
						return false
					}
				}
			}
		}

		document?.removeTablet(tablet)
		self.sentenceEditor?.configure(nil, variant: .Read, delegate: nil)
		documentView.removeTablet(tablet)
		workspaceView.magnifyView(nil)
		
		for cvc in self.childViewControllers {
			if let child = cvc as? QBEChainViewController {
				if child.chain?.tablet == tablet {
					child.removeFromParentViewController()
				}
			}
		}
		
		self.view.window?.makeFirstResponder(self.documentView)
		updateView()
		
		// Register undo operation. Do not retain the QBETablet but instead serialize, so all caches are properly destroyed.
		if undo {
			let data = NSKeyedArchiver.archivedDataWithRootObject(tablet)
			
			if let um = undoManager {
				um.registerUndoWithTarget(self, selector: Selector("addTabletFromArchivedData:"), object: data)
				um.setActionName(NSLocalizedString("Remove tablet", comment: ""))
			}
		}
		return true
	}
	
	private var defaultTabletFrame: CGRect { get {
		let vr = self.workspaceView.documentVisibleRect
		let defaultWidth: CGFloat = min(800, vr.size.width * 0.8 * self.workspaceView.magnification)
		let defaultHeight: CGFloat = min(600, vr.size.height * 0.8 * self.workspaceView.magnification)
		
		// If this is not the first view, place it to the right of all other views
		if let ab = documentView.boundsOfAllTablets {
			return CGRectMake(ab.origin.x + ab.size.width + 10, ab.origin.y + ((ab.size.height - defaultHeight) / 2), defaultWidth, defaultHeight)
		}
		else {
			// If this is the first view, just center it in the visible rect
			return CGRectMake(vr.origin.x + (vr.size.width - defaultWidth) / 2, vr.origin.y + (vr.size.height - defaultHeight) / 2, defaultWidth, defaultHeight)
		}
	} }
	
	func addTablet(tablet: QBETablet, atLocation location: CGPoint?, undo: Bool) {
		// By default, tablets get a size that (when at 100% zoom) fills about 61% horizontally/vertically
		if tablet.frame == nil {
			tablet.frame = defaultTabletFrame
		}
		
		if let l = location {
			tablet.frame = tablet.frame!.centeredAt(l)
		}
		
		self.addTablet(tablet, undo: undo, animated: true)
	}
	
	@objc func addTabletFromArchivedData(data: NSData) {
		if let t = NSKeyedUnarchiver.unarchiveObjectWithData(data) as? QBETablet {
			self.addTablet(t, undo: false, animated: true)
		}
	}
	
	@objc func addTablet(tablet: QBETablet, undo: Bool, animated: Bool, configureAfterAdding: Bool = false) {
		self.workspaceView.magnifyView(nil) {
			// Check if this tablet is also in the document
			if let d = self.document where tablet.document != self.document {
				d.addTablet(tablet)
			}
			
			if tablet.frame == nil {
				tablet.frame = self.defaultTabletFrame
			}

			if let tabletController = self.storyboard?.instantiateControllerWithIdentifier("chain") as? QBEChainViewController {
				tabletController.delegate = self

				self.addChildViewController(tabletController)
				tabletController.chain = tablet.chain
				tabletController.view.frame = tablet.frame!
				
				self.documentView.addTablet(tabletController, animated: animated) {
					self.documentView.selectTablet(tablet)

					if configureAfterAdding {
						self.sentenceEditor?.configure(self)
					}
				}
			}
			self.updateView()
		}
	}
	
	private func updateView() {
		self.workspaceView.hasHorizontalScroller = (self.document?.tablets.count ?? 0) > 0
		self.workspaceView.hasVerticalScroller = (self.document?.tablets.count ?? 0) > 0
		self.welcomeLabel.hidden = (self.document?.tablets.count ?? 0) != 0

		// Apparently, starting in El Capitan, the label does not repaint itself automatically and stays in view after setting hidden=true
		self.welcomeLabel.setNeedsDisplay()
		self.view.setNeedsDisplayInRect(self.view.bounds)
	}
	
	private func zoomToAll(animated: Bool = true) {
		if let ab = documentView.boundsOfAllTablets {
			if self.workspaceView.magnifiedView != nil {
				self.workspaceView.magnifyView(nil) {
					self.documentView.resizeDocument()
				}
			}
			else {
				if animated {
					NSAnimationContext.runAnimationGroup({ (ac) -> Void in
						ac.duration = 0.3
						self.workspaceView.animator().magnifyToFitRect(ab)
					}, completionHandler: nil)
				}
				else {
					self.workspaceView.magnifyToFitRect(ab)
				}
			}
		}
	}

	@IBAction func selectPreviousTablet(sender: NSObject) {
		cycleTablets(-1)
	}

	@IBAction func selectNextTablet(sender: NSObject) {
		cycleTablets(1)
	}

	private func cycleTablets(offset: Int) {
		if let d = self.document where d.tablets.count > 0 {
			let currentTablet = documentView.selectedTablet ?? d.tablets[0]
			if let index = d.tablets.indexOf(currentTablet) {
				let nextIndex = (index+offset) % d.tablets.count
				let nextTablet = d.tablets[nextIndex]
				self.documentView.selectTablet(nextTablet)
				if let selectedView = documentView.selectedTabletController?.view.superview {
					if self.workspaceView.magnification != 1.0 {
						self.workspaceView.zoomView(selectedView)
					}
					else {
						self.workspaceView.animator().magnifyToFitRect(selectedView.frame)
						//selectedView.scrollRectToVisible(selectedView.bounds)
					}
				}
			}
		}
	}

	@objc func exportView(view: QBEExportViewController, finishedExportingTo: NSURL) {
		if let ext = finishedExportingTo.pathExtension {
			if QBEFactory.sharedInstance.fileTypesForReading.contains(ext) {
				self.addTabletFromURL(finishedExportingTo)
			}
		}
	}

	@IBAction func zoomToAll(sender: NSObject) {
		zoomToAll()
	}
	
	func documentView(view: QBEDocumentView, wantsZoomToView: NSView) {
		workspaceView.zoomView(wantsZoomToView)
		documentView.reloadData()
	}
	
	@IBAction func zoomSelection(sender: NSObject) {
		if let selectedView = documentView.selectedTabletController?.view.superview {
			workspaceView.zoomView(selectedView)
			documentView.reloadData()
		}
	}
	
	@IBAction func paste(sender: NSObject) {
		// Pasting a step?
		let pboard = NSPasteboard.generalPasteboard()
		if let data = pboard.dataForType(QBEStep.dragType) {
			if let step = NSKeyedUnarchiver.unarchiveObjectWithData(data) as? QBEStep {
				self.addTablet(QBETablet(chain: QBEChain(head: step)), undo: true, animated: true)
			}
		}
		else {
			// No? Maybe we're pasting TSV/CSV data...
			var data = pboard.stringForType(NSPasteboardTypeString)
			if data == nil {
				data = pboard.stringForType(NSPasteboardTypeTabularText)
			}
			
			if let tsvString = data {
				var data: [QBETuple] = []
				var headerRow: QBETuple? = nil
				let rows = tsvString.componentsSeparatedByString("\r")
				for row in rows {
					var rowValues: [QBEValue] = []
					
					let cells = row.componentsSeparatedByString("\t")
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
					let raster = QBERaster(data: data, columnNames: headerRow!.map({return QBEColumn($0.stringValue ?? "")}), readOnly: false)
					let s = QBERasterStep(raster: raster)
					let tablet = QBETablet(chain: QBEChain(head: s))
					addTablet(tablet, undo: true, animated: true)
				}
			}
		}
	}
	
	@IBAction func addButtonClicked(sender: NSView) {
		// Populate the 'copy of source step' sub menu
		class QBETemplateAdder: NSObject {
			var templateSteps: [QBEStep] = []
			var documentView: QBEDocumentViewController

			init(documentView: QBEDocumentViewController) {
				self.documentView = documentView
			}

			@objc func readdStep(sender: NSMenuItem) {
				if sender.tag >= 0 && sender.tag < templateSteps.count {
					let templateStep = templateSteps[sender.tag]
					let templateData = NSKeyedArchiver.archivedDataWithRootObject(templateStep)
					let newStep = NSKeyedUnarchiver.unarchiveObjectWithData(templateData) as? QBEStep
					let tablet = QBETablet(chain: QBEChain(head: newStep))
					self.documentView.addTablet(tablet, undo: true, animated: true, configureAfterAdding: true)
				}
			}
		}

		let adder = QBETemplateAdder(documentView: self)
		readdTabletMenu.removeAllItems()
		if let d = self.document {
			for tablet in d.tablets {
				for step in tablet.chain.steps {
					if step.previous == nil {
						// This is a source step
						let item = NSMenuItem(title: step.sentence(self.locale, variant: .Read).stringValue, action: Selector("readdStep:"), keyEquivalent: "")
						item.enabled = true
						item.tag = adder.templateSteps.count
						item.target = adder
						adder.templateSteps.append(step)
						readdTabletMenu.addItem(item)
					}
				}
			}
		}

		// The re-add menu item is hidden when the menu is opened from the context menu
		readdMenuItem.hidden = false
		readdMenuItem.enabled = !adder.templateSteps.isEmpty
		NSMenu.popUpContextMenu(self.addTabletMenu, withEvent: NSApplication.sharedApplication().currentEvent!, forView: self.view)
		readdMenuItem.enabled = false
		readdMenuItem.hidden = true
	}

	/** Called when an outlet is dropped onto the workspace itself (e.g. an empty spot). */
	func workspaceView(view: QBEWorkspaceView, didReceiveChain chain: QBEChain, atLocation: CGPoint) {
		QBEAssertMainThread()

		class QBEDropAction: NSObject {
			private var chain: QBEChain
			private var documentView: QBEDocumentViewController
			private var location: CGPoint

			init(chain: QBEChain, documentView: QBEDocumentViewController, location: CGPoint) {
				self.chain = chain
				self.documentView = documentView
				self.location = location
			}

			@objc func addClone(sender: NSObject) {
				let tablet = QBETablet(chain: QBEChain(head: QBECloneStep(chain: chain)))
				self.documentView.addTablet(tablet, atLocation: location, undo: true)
			}

			@objc func addCopy(sender: NSObject) {
				let job = QBEJob(.UserInitiated)
				QBEAppDelegate.sharedInstance.jobsManager.addJob(job, description: NSLocalizedString("Create copy of data here", comment: ""))
				chain.head?.fullData(job) { result in
					switch result {
					case .Success(let fd):
						fd.raster(job) { result in
							switch result {
							case .Success(let raster):
								QBEAsyncMain {
									let tablet = QBETablet(chain: QBEChain(head: QBERasterStep(raster: raster)))
									self.documentView.addTablet(tablet, atLocation: self.location, undo: true)
								}
							case .Failure(let e):
								QBEAsyncMain {
									NSAlert.showSimpleAlert(NSLocalizedString("Could not copy the data",comment: ""), infoText: e, style: .CriticalAlertStyle, window: self.documentView.view.window)
								}
							}
						}
					case .Failure(let e):
						QBEAsyncMain {
							NSAlert.showSimpleAlert(NSLocalizedString("Could not copy the data",comment: ""), infoText: e, style: .CriticalAlertStyle, window: self.documentView.view.window)
						}
					}
				}
			}

			@objc func exportFile(sender: NSObject) {
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

			private func exportToFile(url: NSURL) {
				let writerType: QBEFileWriter.Type
				if let ext = url.pathExtension {
					writerType = QBEFactory.sharedInstance.fileWriterForType(ext) ?? QBECSVWriter.self
				}
				else {
					writerType = QBECSVWriter.self
				}

				let title = chain.tablet?.displayName ?? NSLocalizedString("Warp data", comment: "")
				let s = QBEExportStep(previous: chain.head!, writer: writerType.init(locale: self.documentView.locale, title: title), file: QBEFileReference.URL(url))

				if let editorController = self.documentView.storyboard?.instantiateControllerWithIdentifier("exportEditor") as? QBEExportViewController {
					editorController.step = s
					editorController.delegate = self.documentView
					editorController.locale = self.documentView.locale
					self.documentView.presentViewControllerAsSheet(editorController)
				}
			}

			@objc func saveToWarehouse(sender: NSObject) {
				let stepTypes = QBEFactory.sharedInstance.dataWarehouseSteps
				if let s = sender as? NSMenuItem where s.tag >= 0 && s.tag <= stepTypes.count {
					let stepType = stepTypes[s.tag]

					let uploadView = self.documentView.storyboard?.instantiateControllerWithIdentifier("uploadData") as! QBEUploadViewController
					let targetStep = stepType.init()
					uploadView.targetStep = targetStep
					uploadView.sourceStep = chain.head
					uploadView.afterSuccessfulUpload = {
						// Add the written data as tablet to the document view
						QBEAsyncMain {
							let tablet = QBETablet(chain: QBEChain(head: targetStep))
							self.documentView.addTablet(tablet, atLocation: self.location, undo: true)
						}
					}
					self.documentView.presentViewControllerAsSheet(uploadView)
				}
			}

			func present() {
				let menu = NSMenu()
				menu.autoenablesItems = false

				let cloneItem = NSMenuItem(title: NSLocalizedString("Create linked clone of data here", comment: ""), action: Selector("addClone:"), keyEquivalent: "")
				cloneItem.target = self
				menu.addItem(cloneItem)

				let copyItem = NSMenuItem(title: NSLocalizedString("Create copy of data here", comment: ""), action: Selector("addCopy:"), keyEquivalent: "")
				copyItem.target = self
				menu.addItem(copyItem)
				menu.addItem(NSMenuItem.separatorItem())

				let stepTypes = QBEFactory.sharedInstance.dataWarehouseSteps

				for i in 0..<stepTypes.count {
					let stepType = stepTypes[i]
					if let name = QBEFactory.sharedInstance.dataWarehouseStepNames[stepType.className()] {
						let saveItem = NSMenuItem(title: String(format: NSLocalizedString("Upload data to %@...", comment: ""), name), action: Selector("saveToWarehouse:"), keyEquivalent: "")
						saveItem.target = self
						saveItem.tag = i
						menu.addItem(saveItem)
					}
				}

				menu.addItem(NSMenuItem.separatorItem())
				let exportFileItem = NSMenuItem(title: NSLocalizedString("Export data to file...", comment: ""), action: Selector("exportFile:"), keyEquivalent: "")
				exportFileItem.target = self
				menu.addItem(exportFileItem)

				NSMenu.popUpContextMenu(menu, withEvent: NSApplication.sharedApplication().currentEvent!, forView: self.documentView.view)
			}
		}

		if chain.head != nil {
			let ac = QBEDropAction(chain: chain, documentView: self, location: atLocation)
			ac.present()
		}
	}

	func workspaceView(view: QBEWorkspaceView, didRecieveColumnSet colset: [QBEColumn], fromDataViewController dc: QBEDataViewController) {
		if colset.count == 1 {
			if let sourceChainController = dc.parentViewController as? QBEChainViewController, let step = sourceChainController.chain?.head {
				let job = QBEJob(.UserInitiated)
				step.fullData(job) { result in
					switch result {
					case .Success(let data):
						data.unique(QBESiblingExpression(columnName: colset.first!), job: job) { result in
							switch result {
							case .Success(let uniqueValues):
								let rows = uniqueValues.map({ item in return [item] })
								let raster = QBERaster(data: rows, columnNames: [colset.first!], readOnly: false)
								let chain = QBEChain(head: QBERasterStep(raster: raster))
								let tablet = QBETablet(chain: chain)
								QBEAsyncMain {
									self.addTablet(tablet, atLocation: nil, undo: true)

									let joinStep = QBEJoinStep(previous: nil)
									joinStep.joinType = QBEJoinType.LeftJoin
									joinStep.condition = QBEBinaryExpression(first: QBESiblingExpression(columnName: colset.first!), second: QBEForeignExpression(columnName: colset.first!), type: .Equal)
									joinStep.right = chain
									sourceChainController.chain?.insertStep(joinStep, afterStep: sourceChainController.chain?.head)
									sourceChainController.currentStep = joinStep
								}

							case .Failure(_):
								break
							}

						}

					case .Failure(_):
						break
					}
				}
			}
		}
		else {
			// Do something with more than one column (multijoin)
		}
	}
	
	func workspaceView(view: QBEWorkspaceView, didReceiveFiles files: [String], atLocation: CGPoint) {
		// Gather file paths
		var tabletsAdded: [QBETablet] = []
		
		for file in files {
			var isDirectory: ObjCBool = false
			NSFileManager.defaultManager().fileExistsAtPath(file, isDirectory: &isDirectory)
			if isDirectory {
				// Find the contents of the directory, and add.
				if let enumerator = NSFileManager.defaultManager().enumeratorAtPath(file) {
					for child in enumerator {
						if let cn = child as? String {
							let childName = NSString(string: cn)
							// Skip UNIX hidden files (e.g. .DS_Store).
							// TODO: check Finder 'hidden' bit here like so: http://stackoverflow.com/questions/1140235/is-the-file-hidden
							if !childName.lastPathComponent.hasPrefix(".") {
								let childPath = NSString(string: file).stringByAppendingPathComponent(childName as String)
								
								// Is  the enumerated item a directory? Then ignore it, the enumerator already recurses
								var isChildDirectory: ObjCBool = false
								NSFileManager.defaultManager().fileExistsAtPath(childPath, isDirectory: &isChildDirectory)
								if !isChildDirectory {
									if let t = addTabletFromURL(NSURL(fileURLWithPath: childPath)) {
										tabletsAdded.append(t)
									}
								}
							}
						}
					}
				}
			}
			else {
				if let t = addTabletFromURL(NSURL(fileURLWithPath: file)) {
					tabletsAdded.append(t)
				}
			}
		}
		
		// Zoom to all newly added tablets
		var allRect = CGRectZero
		for tablet in tabletsAdded {
			if let f = tablet.frame {
				allRect = CGRectUnion(allRect, f)
			}
		}
		self.workspaceView.magnifyToFitRect(allRect)
	}
	
	func documentView(view: QBEDocumentView, didSelectArrow arrow: QBEArrow?) {
		if let ta = arrow as? QBETabletArrow {
			if let fromStep = ta.fromStep, let fromTablet = ta.from {
				findAndSelectStep(fromStep, inChain: fromTablet.chain)
			}
		}
	}
	
	func findAndSelectStep(step: QBEStep, inChain chain: QBEChain) {
		if let tablet = chain.tablet {
			for cvc in self.childViewControllers {
				if let child = cvc as? QBEChainViewController {
					if child.chain?.tablet == tablet {
						documentView.selectTablet(tablet)
						child.view.superview?.orderFront()
						didSelectTablet(child)
						child.currentStep = step
					}
				}
			}
		}
	}
	
	private func didSelectTablet(tabletViewController: QBEChainViewController?) {
		for childController in self.childViewControllers {
			if let cvc = childController as? QBEChainViewController {
				if cvc != tabletViewController {
					cvc.tabletWasDeselected()
				}
			}
		}

		if let tv = tabletViewController {
			tv.tabletWasSelected()
		}
		else {
			self.sentenceEditor?.configure(nil, variant: .Neutral, delegate: nil)
		}
		self.view.window?.update()
		self.view.window?.toolbar?.validateVisibleItems()
	}
	
	func documentView(view: QBEDocumentView, didSelectTablet tablet: QBEChainViewController?) {
		didSelectTablet(tablet)
	}
	
	private func addTabletFromURL(url: NSURL, atLocation: CGPoint? = nil) -> QBETablet? {
		QBEAssertMainThread()
		let sourceStep = QBEFactory.sharedInstance.stepForReadingFile(url)
		
		if sourceStep != nil {
			let tablet = QBETablet(chain: QBEChain(head: sourceStep))
			self.addTablet(tablet, atLocation: atLocation, undo: true)
			return tablet
		}
		else {
			let alert = NSAlert()
			alert.messageText = String(format: NSLocalizedString("Unknown file type '%@'.", comment: ""), (url.pathExtension ?? ""))
			alert.alertStyle = NSAlertStyle.WarningAlertStyle
			alert.beginSheetModalForWindow(self.view.window!, completionHandler: { (result: NSModalResponse) -> Void in
				// Do nothing...
			})
			return nil
		}
	}

	func alterTableView(view: QBEAlterTableViewController, didAlterTable mutableData: QBEMutableData?) {
		let job = QBEJob(.UserInitiated)
		mutableData?.data(job) {result in
			switch result {
			case .Success(let data):
				data.raster(job) { result in
					switch result {
					case .Success(let raster):
						QBEAsyncMain {
							let tablet = QBETablet(chain: QBEChain(head: QBERasterStep(raster: raster)))
							self.addTablet(tablet, atLocation: nil, undo: true)
						}

					case .Failure(let e):
						QBEAsyncMain {
							NSAlert.showSimpleAlert(NSLocalizedString("Could not add table", comment: ""), infoText: e, style: .CriticalAlertStyle, window: self.view.window)
						}
					}
				}

			case .Failure(let e):
				QBEAsyncMain {
					NSAlert.showSimpleAlert(NSLocalizedString("Could not add table", comment: ""), infoText: e, style: .CriticalAlertStyle, window: self.view.window)
				}
			}
		}
	}

	@IBAction func addRasterTablet(sender: NSObject) {
		let creator = QBEAlterTableViewController()
		creator.warehouse = QBERasterDataWarehouse()
		creator.delegate = self
		self.presentViewControllerAsSheet(creator)
	}

	@IBAction func addSequencerTablet(sender: NSObject) {
		let chain = QBEChain(head: QBESequencerStep(pattern: "[A-Z]{4}", column: QBEColumn(NSLocalizedString("Value", comment: ""))))
		let tablet = QBETablet(chain: chain)
		self.addTablet(tablet, undo: true, animated: true)
	}
	
	@IBAction func addTabletFromFile(sender: NSObject) {
		let no = NSOpenPanel()
		no.canChooseFiles = true
		no.allowsMultipleSelection = true
		no.allowedFileTypes?.append("public.text")
		//	= NSArray(arrayLiteral: "public.text") // QBEFactory.sharedInstance.fileTypesForReading
		
		no.beginSheetModalForWindow(self.view.window!, completionHandler: { (result: Int) -> Void in
			if result==NSFileHandlingPanelOKButton {
				for url in no.URLs {
					self.addTabletFromURL(url)
				}
			}
		})
	}
	
	@IBAction func addTabletFromPresto(sender: NSObject) {
		self.addTablet(QBETablet(chain: QBEChain(head: QBEPrestoSourceStep())), undo: true, animated: true, configureAfterAdding: true)
	}
	
	@IBAction func addTabletFromMySQL(sender: NSObject) {
		let s = QBEMySQLSourceStep(host: "127.0.0.1", port: 3306, user: "root", database: "test", tableName: "test")
		self.addTablet(QBETablet(chain: QBEChain(head: s)), undo: true, animated: true, configureAfterAdding: true)
	}

	@IBAction func addTabletFromRethinkDB(sender: NSObject) {
		let s = QBERethinkSourceStep(previous: nil)
		self.addTablet(QBETablet(chain: QBEChain(head: s)), undo: true, animated: true, configureAfterAdding: true)
	}
	
	@IBAction func addTabletFromPostgres(sender: NSObject) {
		let s = QBEPostgresSourceStep(host: "127.0.0.1", port: 5432, user: "postgres", database: "postgres", schemaName: "public", tableName: "")
		self.addTablet(QBETablet(chain: QBEChain(head: s)), undo: true, animated: true, configureAfterAdding: true)
	}
	
	override func prepareForSegue(segue: NSStoryboardSegue, sender: AnyObject?) {
		if segue.identifier == "sentence" {
			self.sentenceEditor = segue.destinationController as? QBESentenceViewController
		}
	}
	
	@IBAction func setFullWorkingSet(sender: NSObject) {
		if let t = documentView.selectedTabletController {
			t.setFullWorkingSet(sender)
		}
	}
	
	@IBAction func cancelCalculation(sender: NSObject) {
		if let t = documentView.selectedTabletController {
			t.cancelCalculation(sender)
		}
	}
	
	@IBAction func showSuggestions(sender: NSObject) {
		if let t = documentView.selectedTabletController {
			t.showSuggestions(sender)
		}
	}
	
	@IBAction func exportFile(sender: NSObject) {
		if let t = documentView.selectedTabletController {
			t.exportFile(sender)
		}
	}

	func validateUserInterfaceItem(item: NSValidatedUserInterfaceItem) -> Bool {
			return validateSelector(item.action())
	}

	override func validateToolbarItem(theItem: NSToolbarItem) -> Bool {
		return validateSelector(theItem.action)
	}

	@IBAction func zoomSegment(sender: NSSegmentedControl) {
		if sender.selectedSegment == 0 {
			self.zoomToAll(sender)
		}
		else if sender.selectedSegment == 1 {
			self.zoomSelection(sender)
		}
	}

	private func validateSelector(selector: Selector) -> Bool {
		if selector == Selector("selectNextTablet:") { return (self.document?.tablets.count > 0) ?? false }
		if selector == Selector("selectPreviousTablet:") { return (self.document?.tablets.count > 0) ?? false }
		if selector == Selector("addButtonClicked:") { return true }
		if selector == Selector("addSequencerTablet:") { return true }
		if selector == Selector("addRasterTablet:") { return true }
		if selector == Selector("addTabletFromFile:") { return true }
		if selector == Selector("addTabletFromPresto:") { return true }
		if selector == Selector("addTabletFromMySQL:") { return true }
		if selector == Selector("addTabletFromRethinkDB:") { return true }
		if selector == Selector("addTabletFromPostgres:") { return true }
		if selector == Selector("updateFromFormulaField:") { return true }
		if selector == Selector("zoomSegment:") { return documentView.boundsOfAllTablets != nil }
		if selector == Selector("zoomToAll:") { return documentView.boundsOfAllTablets != nil }
		if selector == Selector("zoomSelection:") { return documentView.selectedTablet != nil }
		if selector == Selector("delete:") { return true }
		if selector == Selector("paste:") {
			let pboard = NSPasteboard.generalPasteboard()
			if pboard.dataForType(QBEStep.dragType) != nil || pboard.dataForType(NSPasteboardTypeString) != nil || pboard.dataForType(NSPasteboardTypeTabularText) != nil {
				return true
			}
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