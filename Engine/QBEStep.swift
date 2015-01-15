import Foundation

class QBEStep: NSObject {
	var exampleData: QBEData? {
		get {
			return apply(self.previous?.exampleData)
		}
	}
	
	var fullData: QBEData? {
		get {
			return apply(self.previous?.fullData)
		}
	}
	
	var previous: QBEStep?
	var next: QBEStep?
	var explanation: NSAttributedString?
	
	func description(locale: QBELocale) -> String {
		return NSLocalizedString("Unknown step", comment: "")
	}
	
	override private init() {
		self.explanation = NSAttributedString(string: "Hello")
	}
	
	required init(coder aDecoder: NSCoder) {
		previous = aDecoder.decodeObjectForKey("previousStep") as? QBEStep
		next = aDecoder.decodeObjectForKey("nextStep") as? QBEStep
		explanation = aDecoder.decodeObjectForKey("explanation") as? NSAttributedString
	}
	
	func encodeWithCoder(coder: NSCoder) {
		coder.encodeObject(previous, forKey: "previousStep")
		coder.encodeObject(next, forKey: "nextStep")
		coder.encodeObject(explanation, forKey: "explanation")
	}
	
	init(previous: QBEStep?) {
		self.previous = previous
	}
	
	func apply(data: QBEData?) -> QBEData? {
		return nil
	}
}

class QBETransposeStep: QBEStep {
	override func apply(data: QBEData?) -> QBEData? {
		return data?.transpose()
	}
	
	override func description(locale: QBELocale) -> String {
		return NSLocalizedString("Switch rows/columns", comment: "")
	}
}