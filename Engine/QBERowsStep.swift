import Foundation

class QBERowsStep: NSObject {
	class func suggest(selectRows: NSIndexSet, inRaster: QBERaster, fromStep: QBEStep?) -> [QBEStep] {
		var suggestions: [QBEStep] = []
		
		// Is the selection contiguous from the top? Then suggest a limit selection
		var contiguousTop = true
		for index in 0..<selectRows.count {
			if !selectRows.containsIndex(index) {
				contiguousTop = false
				break
			}
		}
		if contiguousTop {
			suggestions.append(QBELimitStep(previous: fromStep, numberOfRows: selectRows.count))
		}
		
		// Suggest a random selection
		suggestions.append(QBERandomStep(previous: fromStep, numberOfRows: selectRows.count))
		
		return suggestions
	}
}

class QBELimitStep: QBEStep {
	var numberOfRows: Int
	
	init(previous: QBEStep?, numberOfRows: Int) {
		self.numberOfRows = numberOfRows
		super.init(previous: previous)
	}
	
	override func explain(locale: QBELocale) -> String {
		return String(format: NSLocalizedString("Select the top %d rows", comment: ""), numberOfRows)
	}
	
	required init(coder aDecoder: NSCoder) {
		numberOfRows = Int(aDecoder.decodeIntForKey("numberOfRows"))
		super.init(coder: aDecoder)
	}
	
	override func encodeWithCoder(coder: NSCoder) {
		super.encodeWithCoder(coder)
		coder.encodeInt(Int32(numberOfRows), forKey: "numberOfRows")
	}
	
	override func apply(data: QBEData?, callback: (QBEData?) -> ()) {
		callback(data?.limit(numberOfRows))
	}
}

class QBERandomStep: QBELimitStep {
	override init(previous: QBEStep?, numberOfRows: Int) {
		super.init(previous: previous, numberOfRows: numberOfRows)
	}
	
	override func explain(locale: QBELocale) -> String {
		return String(format: NSLocalizedString("Randomly select %d rows", comment: ""), numberOfRows)
	}
	
	required init(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)
	}
	
	override func encodeWithCoder(coder: NSCoder) {
		super.encodeWithCoder(coder)
	}
	
	override func apply(data: QBEData?, callback: (QBEData?) -> ()) {
		callback(data?.random(numberOfRows))
	}
}

class QBEDistinctStep: QBEStep {
	override init(previous: QBEStep?) {
		super.init(previous: previous)
	}
	
	override func explain(locale: QBELocale) -> String {
		return NSLocalizedString("Remove duplicate rows", comment: "")
	}
	
	required init(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)
	}
	
	override func encodeWithCoder(coder: NSCoder) {
		super.encodeWithCoder(coder)
	}
	
	override func apply(data: QBEData?, callback: (QBEData?) -> ()) {
		callback(data?.distinct())
	}
}