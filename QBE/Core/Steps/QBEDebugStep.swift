import Foundation

class QBEDebugStep: QBEStep, NSSecureCoding {
	enum QBEDebugType: Int {
		case None = 0
		case Rasterize = 1
		case Cache = 2
		
		var description: String { get {
			switch self {
				case .None:
					return NSLocalizedString("(No action)", comment: "")
				
				case .Rasterize:
					return NSLocalizedString("Download data to memory", comment: "")
				
				case .Cache:
					return NSLocalizedString("Download data to SQLite", comment: "")
			}
		} }
	}
	
	var type: QBEDebugType = .None
	
	override init(previous: QBEStep?) {
		super.init(previous: previous)
	}
	
	required init(coder aDecoder: NSCoder) {
		self.type = QBEDebugType(rawValue: aDecoder.decodeIntegerForKey("type")) ?? QBEDebugType.None
		super.init(coder: aDecoder)
	}
	
	static func supportsSecureCoding() -> Bool {
		return true
	}
	
	override func encodeWithCoder(coder: NSCoder) {
		coder.encodeInteger(self.type.rawValue, forKey: "type")
		super.encodeWithCoder(coder)
	}
	
	override func explain(locale: QBELocale, short: Bool) -> String {
		return self.type.description
	}
	
	override func apply(data: QBEFallible<QBEData>, job: QBEJob, callback: (QBEFallible<QBEData>) -> ()) {
		switch type {
			case .None:
				callback(data)
			
			case .Rasterize:
				switch data {
					case .Success(let d):
						d.value.raster(job, callback: { (raster) -> () in
							callback(raster.use({QBERasterData(raster: $0)}))
						})
					
					case .Failure(_):
						callback(data)
				}
			
			case .Cache:
				switch data {
					case .Success(let d):
						/* Make sure the QBESQLiteCachedData object stays around until completion by capturing it in the
						completion callback. Under normal circumstances the object will not keep references to itself 
						and would be released automatically without this trick, because we don't store it. */
						var x: QBESQLiteCachedData? = nil
						x = QBESQLiteCachedData(source: d.value, job: job, completion: {(_) in callback(QBEFallible(x!))})
					
					case .Failure(_):
						callback(data)
				}
			}
	}
}