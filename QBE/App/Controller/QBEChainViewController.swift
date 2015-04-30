import Cocoa

protocol QBESuggestionsViewDelegate: NSObjectProtocol {
	func suggestionsView(view: NSViewController, didSelectStep: QBEStep)
	func suggestionsView(view: NSViewController, didSelectAlternativeStep: QBEStep)
	func suggestionsView(view: NSViewController, previewStep: QBEStep?)
	func suggestionsViewDidCancel(view: NSViewController)
	var currentStep: QBEStep? { get }
	var locale: QBELocale { get }
	var undo: NSUndoManager? { get }
}

protocol QBEChainViewDelegate: NSObjectProtocol {
	/** Called when the chain view wants the delegate to present a configurator for a step. **/
	func chainView(view: QBEChainViewController, configureStep: QBEStep?, delegate: QBESuggestionsViewDelegate)
	
	/** Called when the chain view has a value it wants to present for editing (e.g. in a formula bar). The callback
	 can be called (possibly multiple times) to change the value. If the callback is nil, the value is not changeable. **/
	func chainView(view: QBEChainViewController, editValue: QBEValue, callback: ((QBEValue) -> ())?)
	
	/** Called when the user closes a chain view **/
	func chainViewDidClose(view: QBEChainViewController)
}

internal extension NSViewController {
	internal func showTip(message: String, atView: NSView) {
		QBEAssertMainThread()
		
		if let vc = self.storyboard?.instantiateControllerWithIdentifier("tipController") as? QBETipViewController {
			vc.message = message
			let popover = NSPopover()
			popover.contentViewController = vc
			popover.behavior = NSPopoverBehavior.Transient
			popover.showRelativeToRect(atView.bounds, ofView: atView, preferredEdge: NSMaxYEdge)
		}
	}
}

class QBEChainViewController: NSViewController, QBESuggestionsViewDelegate, QBEDataViewDelegate, QBEStepsControllerDelegate, QBEJobDelegate {
	var suggestions: QBEFuture<[QBEStep]>?
	let calculator: QBECalculator = QBECalculator()
	var dataViewController: QBEDataViewController?
	var stepsViewController: QBEStepsViewController?
	
	@IBOutlet var workingSetSelector: NSSegmentedControl!
	@IBOutlet var suggestionsButton: NSButton!
	weak var delegate: QBEChainViewDelegate?
	
	@IBOutlet var addStepMenu: NSMenu?
	
	internal var useFullData: Bool = false {
		didSet {
			if useFullData != oldValue {
				calculate()
				workingSetSelector.selectedSegment = (useFullData ? 1 : 0)
			}
		}
	}
	
	internal var locale: QBELocale { get {
		return QBEAppDelegate.sharedInstance.locale ?? QBELocale()
	} }
	
	dynamic var currentStep: QBEStep? {
		didSet {
			if let s = currentStep {
				self.previewStep = nil				
				delegate?.chainView(self, configureStep: s, delegate: self)
			}
			else {
				delegate?.chainView(self, configureStep: nil, delegate: self)
				self.presentData(nil)
			}
			
			self.stepsViewController?.currentStep = currentStep
			self.stepsChanged()
		}
	}
	
	var previewStep: QBEStep? {
		didSet {
			if previewStep != currentStep?.previous {
				previewStep?.previous = currentStep?.previous
			}
		}
	}
	
	var chain: QBEChain? {
		didSet {
			self.currentStep = chain?.head
		}
	}
	
	/** Present the given data set in the data grid. This is called by currentStep.didSet as well as previewStep.didSet.
	The data from the previewed step takes precedence. **/
	private func presentData(data: QBEData?) {
		/* TODO: when calculation takes long, it should be cancelled before a new calculation is started. Otherwise the
		contents of the first calculation may be displayed before the second. Perhaps work out a way to cancel
		calculations.*/
		if let d = data {
			if let dataView = self.dataViewController {
				QBEAsyncBackground {
					d.raster(nil, callback: { (raster) -> () in
						QBEAsyncMain {
							self.presentRaster(raster)
						}
					})
				}
			}
		}
		else {
			presentRaster(nil)
		}
	}
	
	private func presentRaster(raster: QBERaster?) {
		if let dataView = self.dataViewController {
			dataView.raster = raster
			
			if raster != nil && raster!.rowCount > 0 {
				if let btn = self.workingSetSelector {
					QBESettings.sharedInstance.once("workingSetTip") {
						self.showTip(NSLocalizedString("By default, Warp shows you a small part of the data. Using this button, you can toggle between the full data and the working selection.",comment: "Working set selector tip"), atView: btn)
					}
				}
			}
		}
	}
	
	func calculate() {
		QBEAssertMainThread()
		
		if let s = currentStep {
			calculator.desiredExampleRows = QBESettings.sharedInstance.exampleMaximumRows
			calculator.maximumExampleTime = QBESettings.sharedInstance.exampleMaximumTime
			
			let sourceStep = previewStep ?? s
			calculator.calculate(sourceStep, fullData: useFullData)
		}
		else {
			calculator.cancel()
		}
		
		refreshData()
	}
	
	private func refreshData() {
		self.presentData(nil)
		dataViewController?.calculating = calculator.calculating
		
		let job = calculator.currentRaster?.get({(raster) in
			QBEAsyncMain {
				self.presentRaster(raster)
			}
		})
		job?.delegate = self
	}
	
	func job(job: QBEJob, didProgress: Double) {
		self.dataViewController?.progress = didProgress
	}
	
	func stepsController(vc: QBEStepsViewController, didSelectStep step: QBEStep) {
		if currentStep != step {
			currentStep = step
			stepsChanged()
			updateView()
			calculate()
		}
	}
	
	func stepsController(vc: QBEStepsViewController, didRemoveStep step: QBEStep) {
		if step == currentStep {
			popStep()
		}
		remove(step)
		stepsChanged()
		updateView()
		calculate()
	}
	
	func stepsController(vc: QBEStepsViewController, didMoveStep: QBEStep, afterStep: QBEStep?) {
		if didMoveStep == currentStep {
			popStep()
		}
		
		// Pull the step from its current location
		var after = afterStep
		
		// If we are inserting after nil, this means inserting as first
		if after == nil {
			remove(didMoveStep)
			
			// Insert at beginning
			if let head = chain?.head {
				after = head
				while after!.previous != nil {
					after = after!.previous
				}
			}
			
			if after == nil {
				// this is the only step
				chain?.head = didMoveStep
			}
			else {
				// insert at beginning
				after!.previous = didMoveStep
			}
		}
		else {
			if after != didMoveStep {
				remove(didMoveStep)
				didMoveStep.next = after?.next
				after?.next?.previous = didMoveStep
				didMoveStep.previous = after
				
				if let h = chain?.head where after == h {
					chain?.head = didMoveStep
				}
			}
		}

		stepsChanged()
		updateView()
		calculate()
	}
	
	func stepsController(vc: QBEStepsViewController, didInsertStep step: QBEStep, afterStep: QBEStep?) {
		if afterStep == nil {
			// Insert at beginning
			if chain?.head != nil {
				var before = chain?.head
				while before!.previous != nil {
					before = before!.previous
				}
				
				before!.previous = step
			}
			else {
				chain?.head = step
			}
		}
		else {
			step.previous = afterStep
			if chain?.head == afterStep {
				chain?.head = step
			}
		}
		stepsChanged()
	}
	
	func dataView(view: QBEDataViewController, didSelectValue: QBEValue, changeable: Bool) {
		delegate?.chainView(self, editValue: didSelectValue, callback: changeable ? {(v) -> () in
			QBEAssertMainThread()
			self.dataViewController?.changeSelectedValue(v)
		} : nil)
	}
	
	func dataView(view: QBEDataViewController, didOrderColumns columns: [QBEColumn], toIndex: Int) -> Bool {
		// Construct a new column ordering
		if let r = view.raster {
			var allColumns = r.columnNames
			if toIndex < allColumns.count {
				pushStep(QBESortColumnsStep(previous: self.currentStep, sortColumns: columns, before: allColumns[toIndex]))
			}
			else {
				pushStep(QBESortColumnsStep(previous: self.currentStep, sortColumns: columns, before: nil))
			}
			calculate()
			return true
		}
		return false
	}

	func dataView(view: QBEDataViewController, didChangeValue: QBEValue, toValue: QBEValue, inRow: Int, column: Int) -> Bool {
		suggestions?.cancel()
		
		calculator.currentRaster?.get({(raster) in
			self.suggestions = QBEFuture<[QBEStep]>({(job, callback) -> () in
				QBEAsyncBackground {
					let expressions = QBECalculateStep.suggest(change: didChangeValue, toValue: toValue, inRaster: raster, row: inRow, column: column, locale: self.locale, job: job)
					callback(expressions.map({QBECalculateStep(previous: self.currentStep, targetColumn: raster.columnNames[column], function: $0)}))
				}
			}, timeLimit: 5.0)
			
			self.suggestions!.get({(steps) -> () in
				QBEAsyncMain {
					self.suggestSteps(steps)
				}
			})
		})
		return false
	}
	
	private func stepsChanged() {
		QBEAssertMainThread()
		self.stepsViewController?.steps = chain?.steps
		self.stepsViewController?.currentStep = currentStep
		updateView()
	}
	
	internal var undo: NSUndoManager? { get { return chain?.tablet?.document?.undoManager } }
	
	private func pushStep(var step: QBEStep) {
		QBEAssertMainThread()
		
		let isHead = chain?.head == nil || currentStep == chain?.head
		
		// Check if this step can (or should) be merged with the step it will be appended after
		if let cs = currentStep {
			switch step.mergeWith(cs) {
				case .Impossible:
					break;
				
				case .Possible:
					break;
				
				case .Advised(let merged):
					popStep()
					remove(cs)
					step = merged
					step.previous = nil
					
					if let v = self.stepsViewController?.view {
						QBESettings.sharedInstance.once("mergeAdvised") {
							self.showTip(NSLocalizedString("Warp has automatically combined your changes with the previous step.", comment: ""), atView: v)
							return
						}
					}
					
					break;
				
				case .Cancels:
					currentStep = cs.previous
					remove(cs)
					if let v = self.stepsViewController?.view {
						QBESettings.sharedInstance.once("mergeCancelOut") {
							self.showTip(NSLocalizedString("Your changes undo the previous step. Warp has therefore automatically removed the previous step.", comment: ""), atView: v)
							return
						}
					}
					return
			}
		}
		
		currentStep?.next?.previous = step
		currentStep?.next = step
		step.previous = currentStep
		currentStep = step

		if isHead {
			chain?.head = step
		}
		
		(undo?.prepareWithInvocationTarget(self) as? QBEChainViewController)?.removeStep(step)
		undo?.setActionName(String(format: NSLocalizedString("Add step '%@'", comment: ""), step.explain(locale, short: true)))
		
		updateView()
		stepsChanged()
	}
	
	private func popStep() {
		currentStep = currentStep?.previous
	}
	
	@IBAction func transposeData(sender: NSObject) {
		if let cs = currentStep {
			suggestSteps([QBETransposeStep(previous: cs)])
		}
	}
	
	func suggestionsView(view: NSViewController, didSelectStep step: QBEStep) {
		previewStep = nil
		pushStep(step)
		stepsChanged()
		updateView()
		calculate()
	}
	
	func suggestionsView(view: NSViewController, didSelectAlternativeStep step: QBEStep) {
		selectAlternativeStep(step)
	}
	
	private func selectAlternativeStep(step: QBEStep) {
		previewStep = nil
		
		// Swap out alternatives
		if var oldAlternatives = currentStep?.alternatives {
			oldAlternatives.remove(step)
			oldAlternatives.append(currentStep!)
			step.alternatives = oldAlternatives
		}
		
		// Swap out step
		let next = currentStep?.next
		let previous = currentStep?.previous
		step.previous = previous
		currentStep = step
		
		if next == nil {
			chain?.head = step
		}
		else {
			next!.previous = step
			step.next = next
		}
		stepsChanged()
		calculate()
	}
	
	func suggestionsView(view: NSViewController, previewStep step: QBEStep?) {
		if step == currentStep || step == nil {
			previewStep = nil
		}
		else {
			previewStep = step
		}
		updateView()
		calculate()
	}
	
	func suggestionsViewDidCancel(view: NSViewController) {
		previewStep = nil
		
		// Close any configuration sheets that may be open
		if let s = self.view.window?.attachedSheet {
			self.view.window?.endSheet(s, returnCode: NSModalResponseOK)
		}
		updateView()
		calculate()
	}
	
	private func updateView() {
		QBEAssertMainThread()
		
		self.suggestionsButton?.hidden = currentStep == nil
		self.suggestionsButton?.enabled = currentStep?.alternatives != nil && currentStep!.alternatives!.count > 0
		
		self.view.window?.update()
	}
	
	private func suggestSteps(var steps: Array<QBEStep>) {
		QBEAssertMainThread()
		
		if steps.count == 0 {
			// Alert
			let alert = NSAlert()
			alert.messageText = NSLocalizedString("I have no idea what you did.", comment: "")
			alert.beginSheetModalForWindow(self.view.window!, completionHandler: { (a: NSModalResponse) -> Void in
			})
		}
		else {
			let step = steps.first!
			pushStep(step)
			steps.remove(step)
			step.alternatives = steps
			updateView()
			calculate()
			
			// Show a tip if there are alternatives
			if steps.count > 1 {
				QBESettings.sharedInstance.once("suggestionsTip") {
					self.showTip(NSLocalizedString("Warp created a step based on your edits. To select an alternative step, click here.", comment: "Tip for suggestions button"), atView: self.suggestionsButton!)
				}
			}
		}
	}
	
	@IBAction func showSuggestions(sender: NSObject) {
		QBEAssertMainThread()
		
		if let s = currentStep?.alternatives where s.count > 0 {
			self.performSegueWithIdentifier("suggestions", sender: sender)
		}
	}
	
	@IBAction func chooseFirstAlternativeStep(sender: NSObject) {
		if let s = currentStep?.alternatives where s.count > 0 {
			selectAlternativeStep(s.first!)
		}
	}
	
	@IBAction func addColumn(sender: NSObject) {
		self.performSegueWithIdentifier("addColumn", sender: sender)
	}
	
	@IBAction func setWorkingSet(sender: NSObject) {
		if let sc = sender as? NSSegmentedControl {
			let changing = (sc.selectedSegment == 1) != useFullData
			calculator.cancel()
			if changing {
				useFullData = (sc.selectedSegment == 1)
			}
			else {
				calculate()
				QBESettings.sharedInstance.once("setWorkingSetReload") {
					self.showTip(NSLocalizedString("If you select the currently active working set, Warp will reload the current working set.", comment: ""), atView: sc)
				}
			}
		}
	}
	
	@IBAction func setFullWorkingSet(sender: NSObject) {
		useFullData = true
	}
	
	@IBAction func setSelectionWorkingSet(sender: NSObject) {
		useFullData = false
	}
	
	@IBAction func addEmptyColumn(sender: NSObject) {
		calculator.currentData?.get({(data) in
			data.columnNames({(cols) in
				// If a column is selected, insert the new column right after it
				var insertAfter: QBEColumn? = nil
				if  let selectedColumns = self.dataViewController?.tableView?.selectedColumnIndexes {
					let firstSelectedColumn = selectedColumns.firstIndex
					if firstSelectedColumn != NSNotFound {
						insertAfter = cols[firstSelectedColumn]
					}
				}
				
				let step = QBECalculateStep(previous: self.currentStep, targetColumn: QBEColumn.defaultColumnForIndex(cols.count), function: QBELiteralExpression(QBEValue.EmptyValue), insertAfter: insertAfter)
				self.pushStep(step)
				self.calculate()
			})
		})
	}
	
	private func remove(stepToRemove: QBEStep) {
		QBEAssertMainThread()
		
		let previous = stepToRemove.previous
		previous?.next = stepToRemove.next
		
		if let next = stepToRemove.next {
			next.previous = previous
			stepToRemove.next = nil
		}
		
		if chain?.head == stepToRemove {
			chain?.head = stepToRemove.previous
		}
		
		stepToRemove.previous = nil
		stepsChanged()
	}
	
	@IBAction func copy(sender: NSObject) {
		QBEAssertMainThread()
		
		if let s = currentStep {
			let pboard = NSPasteboard.generalPasteboard()
			pboard.clearContents()
			pboard.declareTypes([QBEStep.dragType], owner: nil)
			let data = NSKeyedArchiver.archivedDataWithRootObject(s)
			pboard.setData(data, forType: QBEStep.dragType)
		}
	}
	
	@IBAction func removeStep(sender: NSObject) {
		if let stepToRemove = currentStep {
			popStep()
			remove(stepToRemove)
			calculate()
		}
	}
	
	private func sortRows(ascending: Bool) {
		if  let selectedColumns = self.dataViewController?.tableView?.selectedColumnIndexes {
			let firstSelectedColumn = selectedColumns.firstIndex
			if firstSelectedColumn != NSNotFound {
				calculator.currentRaster?.get {(raster) in
					let columnName = raster.columnNames[firstSelectedColumn]
					let expression = QBESiblingExpression(columnName: columnName)
					let order = QBEOrder(expression: expression, ascending: ascending, numeric: true)
					
					QBEAsyncMain {
						self.pushStep(QBESortStep(previous: self.currentStep, orders: [order]))
					}
				}
			}
		}
	}
	
	@IBAction func reverseSortRows(sender: NSObject) {
		sortRows(false)
	}
	
	@IBAction func sortRows(sender: NSObject) {
		sortRows(true)
	}
	
	@IBAction func selectColumns(sender: NSObject) {
		selectColumns(false)
	}
	
	@IBAction func removeColumns(sender: NSObject) {
		selectColumns(true)
	}
	
	private func selectColumns(remove: Bool) {
		if let colsToRemove = dataViewController?.tableView?.selectedColumnIndexes {
			// Get the names of the columns to remove
			calculator.currentRaster?.get({(raster) in
				var namesToRemove: [QBEColumn] = []
				var namesToSelect: [QBEColumn] = []
				
				for i in 0..<raster.columnNames.count {
					if colsToRemove.containsIndex(i) {
						namesToRemove.append(raster.columnNames[i])
					}
					else {
						namesToSelect.append(raster.columnNames[i])
					}
				}
				
				QBEAsyncMain {
					self.suggestSteps([
						QBEColumnsStep(previous: self.currentStep, columnNames: namesToRemove, select: !remove),
						QBEColumnsStep(previous: self.currentStep, columnNames: namesToSelect, select: remove)
					])
				}
			})
		}
	}
	
	@IBAction func randomlySelectRows(sender: NSObject) {
		suggestSteps([QBERandomStep(previous: currentStep, numberOfRows: 1)])
	}
	
	@IBAction func limitRows(sender: NSObject) {
		suggestSteps([QBELimitStep(previous: currentStep, numberOfRows: 1)])
	}
	
	@IBAction func removeRows(sender: NSObject) {
		if let rowsToRemove = dataViewController?.tableView?.selectedRowIndexes {
			if  let selectedColumns = self.dataViewController?.tableView?.selectedColumnIndexes {
				calculator.currentRaster?.get({(raster) in
					// Invert the selection
					let selectedToKeep = NSMutableIndexSet()
					let selectedToRemove = NSMutableIndexSet()
					for index in 0..<raster.rowCount {
						if !rowsToRemove.containsIndex(index) {
							selectedToKeep.addIndex(index)
						}
						else {
							selectedToRemove.addIndex(index)
						}
					}
					
					var relevantColumns = Set<QBEColumn>()
					for columnIndex in 0..<raster.columnCount {
						if selectedColumns.containsIndex(columnIndex) {
							relevantColumns.insert(raster.columnNames[columnIndex])
						}
					}
					
					// Find suggestions for keeping the other rows
					let keepSuggestions = QBERowsStep.suggest(selectedToKeep, columns: relevantColumns, inRaster: raster, fromStep: self.currentStep, select: true)
					var removeSuggestions = QBERowsStep.suggest(selectedToRemove, columns: relevantColumns, inRaster: raster, fromStep: self.currentStep, select: false)
					removeSuggestions.extend(keepSuggestions)
					
					QBEAsyncMain {
						self.suggestSteps(removeSuggestions)
					}
				})
			}
		}
	}
	
	@IBAction func aggregateRowsByCells(sender: NSObject) {
		if let selectedRows = dataViewController?.tableView?.selectedRowIndexes {
			if  let selectedColumns = self.dataViewController?.tableView?.selectedColumnIndexes {
				calculator.currentRaster?.get({(raster) in
					var relevantColumns = Set<QBEColumn>()
					for columnIndex in 0..<raster.columnCount {
						if selectedColumns.containsIndex(columnIndex) {
							relevantColumns.insert(raster.columnNames[columnIndex])
						}
					}
					
					let suggestions = QBEPivotStep.suggest(selectedRows, columns: relevantColumns, inRaster: raster, fromStep: self.currentStep)
					
					QBEAsyncMain {
						self.suggestSteps(suggestions)
					}
				})
			}
		}
	}
	
	@IBAction func selectRows(sender: NSObject) {
		if let selectedRows = dataViewController?.tableView?.selectedRowIndexes {
			if  let selectedColumns = self.dataViewController?.tableView?.selectedColumnIndexes {
				calculator.currentRaster?.get({(raster) in
					var relevantColumns = Set<QBEColumn>()
					for columnIndex in 0..<raster.columnCount {
						if selectedColumns.containsIndex(columnIndex) {
							relevantColumns.insert(raster.columnNames[columnIndex])
						}
					}
					
					let suggestions = QBERowsStep.suggest(selectedRows, columns: relevantColumns, inRaster: raster, fromStep: self.currentStep, select: true)
					
					QBEAsyncMain {
						self.suggestSteps(suggestions)
					}
				})
			}
		}
	}
	
	func validateUserInterfaceItem(item: NSValidatedUserInterfaceItem) -> Bool {
		if item.action()==Selector("transposeData:") {
			return currentStep != nil
		}
		else if item.action()==Selector("aggregateRowsByCells:") {
			if let rowsToAggregate = dataViewController?.tableView?.selectedRowIndexes {
				return rowsToAggregate.count > 0  && currentStep != nil
			}
			return false
		}
		else if item.action()==Selector("removeRows:") {
			if let rowsToRemove = dataViewController?.tableView?.selectedRowIndexes {
				return rowsToRemove.count > 0  && currentStep != nil
			}
			return false
		}
		else if item.action()==Selector("removeColumns:") {
			if let colsToRemove = dataViewController?.tableView?.selectedColumnIndexes {
				return colsToRemove.count > 0 && currentStep != nil
			}
			return false
		}
		else if item.action()==Selector("selectColumns:") {
			if let colsToRemove = dataViewController?.tableView?.selectedColumnIndexes {
				return colsToRemove.count > 0 && currentStep != nil
			}
			return false
		}
		else if item.action()==Selector("addColumn:") {
			return currentStep != nil
		}
		else if item.action()==Selector("addEmptyColumn:") {
			return currentStep != nil
		}
		else if item.action()==Selector("exportFile:") {
			return currentStep != nil
		}
		else if item.action()==Selector("goBack:") {
			return currentStep?.previous != nil
		}
		else if item.action()==Selector("goForward:") {
			return currentStep?.next != nil
		}
		else if item.action()==Selector("calculate:") {
			return currentStep != nil
		}
		else if item.action()==Selector("randomlySelectRows:") {
			return currentStep != nil
		}
		else if item.action()==Selector("limitRows:") {
			return currentStep != nil
		}
		else if item.action()==Selector("pivot:") {
			return currentStep != nil
		}
		else if item.action()==Selector("flatten:") {
			return currentStep != nil
		}
		else if item.action()==Selector("removeStep:") {
			return currentStep != nil
		}
		else if item.action()==Selector("removeDuplicateRows:") {
			return currentStep != nil
		}
		else if item.action()==Selector("selectRows:") {
			return currentStep != nil
		}
		else if item.action()==Selector("showSuggestions:") {
			return currentStep?.alternatives != nil && currentStep!.alternatives!.count > 0
		}
		else if item.action()==Selector("chooseFirstAlternativeStep:") {
			return currentStep?.alternatives != nil && currentStep!.alternatives!.count > 0
		}
		else if item.action()==Selector("setFullWorkingSet:") {
			return currentStep != nil && !useFullData
		}
		else if item.action()==Selector("setSelectionWorkingSet:") {
			return currentStep != nil && useFullData
		}
		else if item.action()==Selector("sortRows:") {
			return currentStep != nil
		}
		else if item.action()==Selector("reverseSortRows:") {
			return currentStep != nil
		}
		else if item.action() == Selector("removeTablet:") {
			return true
		}
		else if item.action()==Selector("paste:") {
			let pboard = NSPasteboard.generalPasteboard()
			if let data = pboard.dataForType(QBEStep.dragType) {
				return true
			}
			return false
		}
		else if item.action() == Selector("copy:") {
			return currentStep != nil
		}
		else {
			return false
		}
	}
	
	@IBAction func removeTablet(sender: NSObject) {
		self.delegate?.chainViewDidClose(self)
	}
	
	@IBAction func removeDuplicateRows(sender: NSObject) {
		pushStep(QBEDistinctStep(previous: self.currentStep))
	}
	
	@IBAction func goBackForward(sender: NSObject) {
		if let segment = sender as? NSSegmentedControl {
			if segment.selectedSegment == 0 {
				self.goBack(sender)
			}
			else if segment.selectedSegment == 1 {
				self.goForward(sender)
			}
			segment.selectedSegment = -1
		}
	}
	
	@IBAction func goBack(sender: NSObject) {
		// Prevent popping the last step (popStep allows it but goBack doesn't)
		if let p = currentStep?.previous {
			currentStep = p
			updateView()
			calculate()
		}
	}
	
	@IBAction func goForward(sender: NSObject) {
		if let n = currentStep?.next {
			currentStep = n
			updateView()
			calculate()
		}
	}
	
	@IBAction func flatten(sender: NSObject) {
		suggestSteps([QBEFlattenStep(previous: currentStep)])
	}
	
	@IBAction func pivot(sender: NSObject) {
		suggestSteps([QBEPivotStep(previous: currentStep)])
	}
	
	@IBAction func exportFile(sender: NSObject) {
		let ns = NSSavePanel()
		ns.allowedFileTypes = QBEFactory.sharedInstance.fileExtensionsForWriting
		let title = chain?.tablet?.document?.displayName ?? NSLocalizedString("Warp data", comment: "")
		
		ns.beginSheetModalForWindow(self.view.window!, completionHandler: { (result: Int) -> Void in
			if result == NSFileHandlingPanelOKButton {
				// What type of file are we exporting?
				QBEAsyncBackground {
					if let cs = self.currentStep {
						cs.fullData(nil, callback: {(data: QBEData) -> () in
							if let url = ns.URL, let ext = url.pathExtension {
								// Get the file writer for this type
								// FIXME: make a registry somewhere
								if let writer = QBEFactory.sharedInstance.fileWriterForType(ext, data: data, locale: self.locale, title: title) {
									writer.writeToFile(url, callback: {
										QBEAsyncMain {
											let alert = NSAlert()
											alert.messageText = String(format: NSLocalizedString("The data has been successfully saved to '%@'.", comment: ""), url.absoluteString ?? "")
											alert.beginSheetModalForWindow(self.view.window!, completionHandler: { (response) -> Void in
											})
										}
									})
								}
							}
						})
					}
				}
			}
		})
	}
	
	override func viewWillAppear() {
		super.viewWillAppear()
		stepsChanged()
		calculate()
	}
	
	override func viewDidAppear() {
		super.viewDidAppear()
		
		if currentStep == nil {
			QBESettings.sharedInstance.once("welcomeTip") {
				if let btn = self.stepsViewController?.addButton {
					self.showTip(NSLocalizedString("Welcome to Warp! Click here to start and load some data.",comment: "Welcome tip"), atView: btn)
				}
			}
		}
	}
	
	override func prepareForSegue(segue: NSStoryboardSegue, sender: AnyObject?) {
		if segue.identifier=="grid" {
			dataViewController = segue.destinationController as? QBEDataViewController
			dataViewController?.delegate = self
			dataViewController?.locale = locale
			calculate()
		}
		else if segue.identifier=="suggestions" {
			let sv = segue.destinationController as? QBESuggestionsViewController
			sv?.delegate = self
			if let alts = currentStep?.alternatives {
				sv?.suggestions = Array(alts)
			}
		}
		else if segue.identifier=="addColumn" {
			let sv = segue.destinationController as? QBEAddColumnViewController
			sv?.delegate = self
		}
		else if segue.identifier=="steps" {
			stepsViewController = segue.destinationController as? QBEStepsViewController
			stepsViewController?.delegate = self
			stepsChanged()
		}
		super.prepareForSegue(segue, sender: sender)
	}
	
	@IBAction func paste(sender: NSObject) {
		let pboard = NSPasteboard.generalPasteboard()
		
		if let data = pboard.dataForType(QBEStep.dragType) {
			if let step = NSKeyedUnarchiver.unarchiveObjectWithData(data) as? QBEStep {
				step.previous = nil
				pushStep(step)
			}
		}
	}
}

class QBETipViewController: NSViewController {
	@IBOutlet var messageLabel: NSTextField? = nil
	
	var message: String = "" { didSet {
		messageLabel?.stringValue = message
	} }
	
	override func viewWillAppear() {
		self.messageLabel?.stringValue = message
	}
}