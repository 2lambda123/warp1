import Foundation

class QBEColumnsStep: QBEStep {
	let columnNames: [QBEColumn]
	let select: Bool
	
	init(previous: QBEStep?, columnNames: [QBEColumn], select: Bool) {
		self.columnNames = columnNames
		self.select = select
		let columnNameStrings = columnNames.map({$0.name})
		
		let explanation = (select ? NSLocalizedString("Select column(s)", comment: "") : NSLocalizedString("Remove column(s)", comment: "")) + " " + (columnNameStrings.implode(", ") ?? "")
		super.init(previous: previous, explanation: explanation)
	}
	
	required init(coder aDecoder: NSCoder) {
		select = aDecoder.decodeBoolForKey("select")
		let names = aDecoder.decodeObjectForKey("columnNames") as? [String] ?? []
		columnNames = names.map({QBEColumn($0)})
		super.init(coder: aDecoder)
	}
	
	override func encodeWithCoder(coder: NSCoder) {
		let columnNameStrings = columnNames.map({$0.name})
		coder.encodeObject(columnNameStrings, forKey: "columnsToRemove")
		coder.encodeBool(select, forKey: "select")
		super.encodeWithCoder(coder)
	}
	
	override func apply(data: QBEData?) -> QBEData? {
		let columns = data?.columnNames.filter({column -> Bool in
			for c in self.columnNames {
				if c == column {
					return self.select
				}
			}
			return !self.select
		}) ?? []
		
		return data?.selectColumns(columns)
	}
}