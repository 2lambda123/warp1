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

class QBEColumnsStep: QBEStep {
	var columns: OrderedSet<Column> = []
	var select: Bool = true

	required init() {
		super.init()
	}

	init(previous: QBEStep?, columns: OrderedSet<Column>, select: Bool) {
		self.columns = columns
		self.select = select
		super.init(previous: previous)
	}

	override func sentence(_ locale: Language, variant: QBESentenceVariant) -> QBESentence {
		let typeItem = QBESentenceOptionsToken(options: [
			"select": (columns.count <= 1 ? "Select column".localized : "Select columns".localized),
			"remove": (columns.count <= 1 ? "Remove column".localized : "Remove columns".localized)
		], value: self.select ? "select" : "remove") { [weak self] newType in
			self?.select = (newType == "select")
		}

		let columnsItem = QBESentenceSetToken(value: Set(self.columns.map { $0.name }), provider: { cb in
			let job = Job(.userInitiated)
			if let previous = self.previous {
				previous.exampleDataset(job, maxInputRows: 100, maxOutputRows: 100) {result in
					switch result {
					case .success(let data):
						data.columns(job) { result in
							switch result {
							case .success(let cns):
								cb(.success(Set(cns.map { $0.name })))

							case .failure(let e):
								cb(.failure(e))
							}
						}
					case .failure(let e):
						cb(.failure(e))
					}
				}
			}
			else {
				cb(.success([]))
			}
		},
		callback: { [weak self] newSet in
			self?.columns = OrderedSet(newSet.map { Column($0) })
		})

		if select {
			if columns.count <= 1 {
				return QBESentence(format: "[#] [#]", typeItem, columnsItem)
			}
			else {
				return QBESentence(format: "[#] [#]", typeItem, columnsItem)
			}
		}
		else {
			if columns.isEmpty {
				return QBESentence(format: "Remove all columns".localized)
			}
			else if columns.count == 1 {
				return QBESentence(format: "[#] [#]", typeItem, columnsItem)
			}
			else {
				return QBESentence(format: "[#] [#]", typeItem, columnsItem)
			}
		}
	}

	required init(coder aDecoder: NSCoder) {
		select = aDecoder.decodeBool(forKey: "select")
		let names = (aDecoder.decodeObject(forKey: "columnNames") as? [String]) ?? []
		columns = OrderedSet<Column>(names.map({Column($0)}))
		super.init(coder: aDecoder)
	}
	
	override func encode(with coder: NSCoder) {
		let columnNameStrings = columns.map({$0.name})
		coder.encode(columnNameStrings, forKey: "columnNames")
		coder.encode(select, forKey: "select")
		super.encode(with: coder)
	}
	
	override func apply(_ data: Dataset, job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		data.columns(job) { (existingColumnsFallible) -> () in
			switch existingColumnsFallible {
				case .success(let existingColumns):
					let columns = OrderedSet(existingColumns.filter({column -> Bool in
						for c in self.columns {
							if c == column {
								return self.select
							}
						}
						return !self.select
					}))
					callback(.success(data.selectColumns(columns)))
				
				case .failure(let error):
					callback(.failure(error))
			}
		}
	}
	
	override func mergeWith(_ prior: QBEStep) -> QBEStepMerge {
		if let p = prior as? QBEColumnsStep, p.select && self.select {
			// This step can ony be a further subset of the columns selected by the prior
			return QBEStepMerge.advised(self)
		}
		else if let p = prior as? QBEColumnsStep, !p.select && !self.select {
			// This step removes additional columns after the previous one
			var newColumns = p.columns
			self.columns.forEach { cn in
				if !newColumns.contains(cn) {
					newColumns.append(cn)
				}
			}

			return QBEStepMerge.advised(QBEColumnsStep(previous: previous, columns: newColumns, select: false))
		}
		else if let p = prior as? QBECalculateStep {
			let contained = columns.contains(p.targetColumn)
			if (select && !contained) || (!select && contained) {
				let newColumns = OrderedSet(columns.filter({$0 != p.targetColumn}))
				if newColumns.isEmpty {
					return QBEStepMerge.cancels
				}
				else {
					return QBEStepMerge.advised(QBEColumnsStep(previous: previous, columns: newColumns, select: self.select))
				}
			}
		}
		
		return QBEStepMerge.impossible
	}

	override func related(job: Job, callback: @escaping (Fallible<[QBERelatedStep]>) -> ()) {
		super.related(job: job) { result in
			switch result {
			case .success(let relatedSteps):
				return callback(.success(relatedSteps.compactMap { related -> QBERelatedStep? in
					switch related {
					case .joinable(step: _, type: _, condition: let expression):
						// Rewrite the join expression to take into account any of our renames
						var stillPossible = true
						expression.visit { e -> () in
							if let sibling = e as? Sibling, (self.columns.contains(sibling.column) && !self.select) || (!self.columns.contains(sibling.column) && self.select) {
								// Column we join on was removed
								stillPossible = false
							}
						}

						if stillPossible {
							return related
						}
						return nil
					}
					}))

			case .failure(let e):
				return callback(.failure(e))
			}
		}
	}
}

class QBESortColumnsStep: QBEStep {
	var sortColumns: OrderedSet<Column> = []
	var before: Column? // nil means: at end

	required init() {
		super.init()
	}
	
	init(previous: QBEStep?, sortColumns: OrderedSet<Column>, before: Column?) {
		self.sortColumns = sortColumns
		self.before = before
		super.init(previous: previous)
	}
	
	private func explanation(_ locale: Language) -> String {
		let destination = before != nil ? String(format: NSLocalizedString("before %@", comment: ""), before!.name) : NSLocalizedString("at the end", comment: "")
		
		if sortColumns.count > 5 {
			return String(format: NSLocalizedString("Place %d columns %@", comment: ""), sortColumns.count, destination)
		}
		else if sortColumns.count == 1 {
			return String(format: NSLocalizedString("Place column %@ %@", comment: ""), sortColumns[0].name, destination)
		}
		else {
			let names = sortColumns.map({it in return it.name}).joined(separator: ", ")
			return String(format: NSLocalizedString("Place columns %@ %@", comment: ""), names, destination)
		}
	}

	override func sentence(_ locale: Language, variant: QBESentenceVariant) -> QBESentence {
		return QBESentence([QBESentenceLabelToken(self.explanation(locale))])
	}
	
	required init(coder aDecoder: NSCoder) {
		let names = (aDecoder.decodeObject(forKey: "sortColumns") as? [String]) ?? []
		self.sortColumns = OrderedSet(names.map({Column($0)}))
		let beforeName = aDecoder.decodeObject(forKey: "before") as? String
		if let b = beforeName {
			self.before = Column(b)
		}
		else {
			self.before = nil
		}
		super.init(coder: aDecoder)
	}
	
	override func encode(with coder: NSCoder) {
		let columnNameStrings = sortColumns.map({$0.name})
		coder.encode(columnNameStrings, forKey: "sortColumns")
		coder.encode(before?.name ?? nil, forKey: "before")
		super.encode(with: coder)
	}
	
	override func apply(_ data: Dataset, job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		data.columns(job) { (existingColumnsFallible) -> () in
			switch existingColumnsFallible {
				case .success(let existingColumns):
					let columnSet = Set(existingColumns)
					var newColumns = existingColumns
					var sortColumns = self.sortColumns
					
					/* Remove the dragged columns from their existing location. If they do not exist, remove them from the
					set of dragged columns. */
					for dragged in self.sortColumns {
						if columnSet.contains(dragged) {
							newColumns.remove(dragged)
						}
						else {
							// Dragging a column that doesn't exist! Ignore
							sortColumns.remove(dragged)
						}
					}
					
					// If we have an insertion point for the set of reordered columns, insert them there
					if let before = self.before, let newIndex = newColumns.firstIndex(of: before) {
						newColumns.insert(contentsOf: self.sortColumns, at: newIndex)
					}
					else {
						// Just append at the end. Happens when self.before is nil or the column indicated in self.before doesn't exist
						sortColumns.forEach { newColumns.append($0) }
					}
					
					// The re-ordering operation may never drop or add columns (even if specified columns do not exist)
					assert(newColumns.count == existingColumns.count, "Re-ordering operation resulted in loss of columns")
					callback(.success(data.selectColumns(newColumns)))
				
				case .failure(let error):
					callback(.failure(error))
			}
		}
	}
}
