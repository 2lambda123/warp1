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

class QBEExplodeVerticallyTransformer: Transformer {
	let splitColumn: Column
	let mode: QBEExplodeMode
	let columnFuture: Future<Fallible<OrderedSet<Column>>>

	init(source: WarpCore.Stream, splitColumn: Column, mode: QBEExplodeMode) {
		self.splitColumn = splitColumn
		self.mode = mode
		self.columnFuture = Future<Fallible<OrderedSet<Column>>>({ (job, callback) in
			source.columns(job, callback: callback)
		})

		super.init(source: source)
	}

	override func transform(_ rows: Array<Tuple>, streamStatus: StreamStatus, job: Job, callback: @escaping Sink) {
		self.columnFuture.get(job) { result in
			switch result {
			case .success(let columns):
				let tuples = rows.flatMap { tuple -> [[Value]] in
					var row = Row(tuple, columns: columns)
					if let valueToSplit = row[self.splitColumn] {
						let pieces = self.mode.split(valueToSplit)

						// Create a row for each value from the list
						return (0..<pieces.count).map { index in
							let piece = pieces[index]
							row[self.splitColumn] = piece
							return row.values
						}
					}
					else {
						// Pass on the row verbatim
						return [tuple]
					}
				}
				return callback(.success(tuples), streamStatus)

			case .failure(let e):
				return callback(.failure(e), .finished)
			}
		}
	}

	override func clone() ->  WarpCore.Stream {
		return QBEExplodeVerticallyTransformer(source: self.source.clone(), splitColumn: self.splitColumn, mode: self.mode)
	}
}

class QBEExplodeHorizontallyTransformer: Transformer {
	let splitColumn: Column
	let mode: QBEExplodeMode
	let targetColumns: OrderedSet<Column>
	let sourceColumnFuture: Future<Fallible<OrderedSet<Column>>>
	let targetColumnFuture: Future<Fallible<OrderedSet<Column>>>

	init(source: WarpCore.Stream, splitColumn: Column, mode: QBEExplodeMode, targetColumns: OrderedSet<Column>) {
		self.splitColumn = splitColumn
		self.mode = mode
		self.targetColumns = targetColumns

		let sourceColumnFuture = Future<Fallible<OrderedSet<Column>>>({ (job, callback) in
			source.columns(job, callback: callback)
		})

		self.sourceColumnFuture = sourceColumnFuture

		self.targetColumnFuture = Future<Fallible<OrderedSet<Column>>>({ (job, callback) in
			sourceColumnFuture.get(job) { result in
				switch result {
				case .success(let sourceColumns):
					var newColumns = sourceColumns
					newColumns.remove(splitColumn)
					let addedColumns = targetColumns.filter { !newColumns.contains($0) }
					newColumns.append(contentsOf: addedColumns)
					return callback(.success(newColumns))

				case .failure(let e):
					return callback(.failure(e))
				}
			}
		})

		super.init(source: source)
	}

	override func transform(_ rows: Array<Tuple>, streamStatus: StreamStatus, job: Job, callback: @escaping Sink) {
		self.targetColumnFuture.get(job) { result in
			switch result {
			case .success(let targetColumns):
				self.sourceColumnFuture.get(job) { result in
					switch result {
					case .success(let sourceColumns):
						let tuples = rows.map { tuple -> [Value] in
							let sourceRow = Row(tuple, columns: sourceColumns)
							var destRow = Row(columns: targetColumns)

							for targetColumn in self.targetColumns {
								// TODO: pre-cache the list of columns that should be migrated over
								if sourceColumns.contains(targetColumn) {
									destRow[targetColumn] = sourceRow[targetColumn]
								}
							}

							if let valueToSplit = sourceRow[self.splitColumn] {
								let pieces = self.mode.split(valueToSplit)
								let pieceCount = min(pieces.count, self.targetColumns.count)

								for index in 0..<pieceCount {
									let piece = pieces[index]
									destRow[self.targetColumns[index]] = piece
								}
							}

							return destRow.values
						}
						return callback(.success(tuples), streamStatus)

					case .failure(let e):
						return callback(.failure(e), .finished)
					}
				}

			case .failure(let e):
				return callback(.failure(e), .finished)
			}
		}
	}

	override func columns(_ job: Job, callback: @escaping (Fallible<OrderedSet<Column>>) -> ()) {
		self.targetColumnFuture.get(job, callback)
	}

	override func clone() ->  WarpCore.Stream {
		return QBEExplodeHorizontallyTransformer(source: self.source.clone(), splitColumn: self.splitColumn, mode: self.mode, targetColumns: self.targetColumns)
	}
}

enum QBEExplodeMode {
	case list
	case pack
	case separator(String)
	case windowsNewLine
	case unixNewLine
	case macNewLine

	var identifier: String {
		switch self {
		case .list: return "list"
		case .pack: return "pack"
		case .separator: return "separator"
		case .windowsNewLine: return "rn"
		case .unixNewLine: return "n"
		case .macNewLine: return "r"
		}
	}

	var separator: String? {
		switch self {
		case .list: return nil
		case .pack: return nil
		case .separator(let sep): return sep
		case .macNewLine: return "\r"
		case .unixNewLine: return "\n"
		case .windowsNewLine: return "\r\n"
		}
	}

	var localizedDescription: String {
		switch self {
		case .list: return "lists".localized
		case .pack: return "packs".localized
		case .separator(_): return "values by separator".localized
		case .windowsNewLine: return "lines (Windows-formatted)".localized
		case .unixNewLine: return "lines (Unix-formatted)".localized
		case .macNewLine: return "lines (legacy Mac-formatted)".localized
		}
	}

	static var allModes: [String: String] {
		let all: [QBEExplodeMode] = [.list, .pack, .separator(Pack.separator), .windowsNewLine, .unixNewLine, .macNewLine]
		return all.mapDictionary { mode in return (mode.identifier, mode.localizedDescription) }
	}

	static func create(identifier: String, defaultSeparator: String = Pack.separator) -> QBEExplodeMode {
		switch identifier {
		case "list": return .list
		case "pack": return .pack
		case "separator": return .separator(defaultSeparator)
		case "rn": return .windowsNewLine
		case "n": return .unixNewLine
		case "r": return .macNewLine
		default: return .pack
		}
	}

	func split(_ value: Value) -> [Value] {
		switch self {
		case .list:
			if case .list(let xs) = value {
				return xs
			}
			else {
				return [value]
			}

		case .pack:
			return (Pack(value)?.items.map { return Value.string($0) }) ?? []

		default:
			return value.stringValue?.components(separatedBy: self.separator!).map { return Value.string($0) } ?? []
		}
	}
}

class QBEExplodeVerticallyStep: QBEStep {
	var splitColumn: Column
	var mode: QBEExplodeMode = .list

	required init() {
		splitColumn = Column("")
		super.init()
	}

	init(previous: QBEStep?, splitColumn: Column) {
		self.splitColumn = splitColumn
		super.init(previous: previous)
	}

	override func sentence(_ locale: Language, variant: QBESentenceVariant) -> QBESentence {
		let modeSelector = QBESentenceOptionsToken(options: QBEExplodeMode.allModes, value: self.mode.identifier) { (newMode) in
			self.mode = QBEExplodeMode.create(identifier: newMode)
		}

		let sourceColumnSelector = QBESentenceDynamicOptionsToken(value: self.splitColumn.name, provider: { [weak self] (callback) in
			let job = Job(.userInitiated)
			self?.previous?.exampleDataset(job, maxInputRows: 0, maxOutputRows: 0, callback: { result in
				switch result {
				case .success(let data):
					data.columns(job) { result in
						switch result {
						case .success(let columns):
							return callback(.success(columns.map { return $0.name }))

						case .failure(let e):
							return callback(.failure(e))
						}
					}

				case .failure(let e):
					return callback(.failure(e))
				}
			})

			}, callback: { (newColumnName) in
				self.splitColumn = Column(newColumnName)
		})

		if case .separator(let sep) = self.mode {
			let separatorSelector = QBESentenceTextToken(value: sep) { (newSeparator) -> (Bool) in
				if !newSeparator.isEmpty {
					self.mode = .separator(newSeparator)
					return true
				}
				return false
			}

			return QBESentence(format: "Split [#] [#] in column [#] and create a row for each item".localized,
			   modeSelector,
			   separatorSelector,
			   sourceColumnSelector
			)
		}
		else {
			return QBESentence(format: "Split [#] in column [#] and create a row for each item".localized,
			   modeSelector,
			   sourceColumnSelector
			)
		}
	}

	required init(coder aDecoder: NSCoder) {
		splitColumn = Column(aDecoder.decodeString(forKey:"splitColumn") ?? "")

		if let mode = aDecoder.decodeString(forKey: "mode"), !mode.isEmpty {
			self.mode = QBEExplodeMode.create(identifier: mode, defaultSeparator: aDecoder.decodeString(forKey: "separator") ?? Pack.separator)
		}
		else {
			if let sep = aDecoder.decodeString(forKey: "separator") {
				self.mode = .separator(sep)
			}
			else {
				self.mode = .pack
			}
		}
		super.init(coder: aDecoder)
	}

	override func encode(with coder: NSCoder) {
		coder.encodeString(self.splitColumn.name, forKey: "splitColumn")
		coder.encodeString(self.mode.identifier, forKey: "mode")
		if case .separator(let sep) = self.mode {
			coder.encodeString(sep, forKey: "separator")
		}
		super.encode(with: coder)
	}

	override func apply(_ data: Dataset, job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		callback(.success(StreamDataset(source: QBEExplodeVerticallyTransformer(source: data.stream(), splitColumn: self.splitColumn, mode: self.mode))))
	}
}

class QBEExplodeHorizontallyStep: QBEStep {
	var mode: QBEExplodeMode
	var splitColumn: Column
	var targetColumns: OrderedSet<Column>

	required init() {
		self.mode = .list
		splitColumn = Column("")
		self.targetColumns = OrderedSet(["A","B","C"].map { return Column($0) })
		super.init()
	}

	init(previous: QBEStep?, splitColumn: Column, by mode: QBEExplodeMode = .list) {
		self.splitColumn = splitColumn
		self.mode = mode
		self.targetColumns = OrderedSet((0..<3).map { return Column(splitColumn.name + "_\($0)") })
		super.init(previous: previous)
	}

	override func sentence(_ locale: Language, variant: QBESentenceVariant) -> QBESentence {
		let modeSelector = QBESentenceOptionsToken(options: QBEExplodeMode.allModes, value: self.mode.identifier) { (newMode) in
			self.mode = QBEExplodeMode.create(identifier: newMode)
		}

		let sourceColumnSelector = QBESentenceDynamicOptionsToken(value: self.splitColumn.name, provider: { [weak self] (callback) in
			let job = Job(.userInitiated)
			self?.previous?.exampleDataset(job, maxInputRows: 0, maxOutputRows: 0, callback: { result in
				switch result {
				case .success(let data):
					data.columns(job) { result in
						switch result {
						case .success(let columns):
							return callback(.success(columns.map { return $0.name }))

						case .failure(let e):
							return callback(.failure(e))
						}
					}

				case .failure(let e):
					return callback(.failure(e))
				}
			})

			}, callback: { (newColumnName) in
				self.splitColumn = Column(newColumnName)
		})

		let targetColumnSelector = QBESentenceColumnsToken(value: self.targetColumns, callback: { (newColumns) in
			self.targetColumns = newColumns
		})

		if case .separator(let sep) = self.mode {
			let separatorSelector = QBESentenceTextToken(value: sep) { (newSeparator) -> (Bool) in
				if !newSeparator.isEmpty {
					self.mode = .separator(newSeparator)
					return true
				}
				return false
			}

			return QBESentence(format: "Split [#] [#] in column [#] to columns [#]".localized,
			   modeSelector,
			   separatorSelector,
			   sourceColumnSelector,
			   targetColumnSelector
			)
		}
		else {
			return QBESentence(format: "Split [#] in column [#] to columns [#]".localized,
			   modeSelector,
			   sourceColumnSelector,
			   targetColumnSelector
			)
		}
	}

	required init(coder aDecoder: NSCoder) {
		splitColumn = Column(aDecoder.decodeString(forKey:"splitColumn") ?? "")
		let names = (aDecoder.decodeObject(forKey: "targetColumns") as? [String]) ?? []
		self.targetColumns = OrderedSet<Column>(names.map { return Column($0) }.uniqueElements)

		if let mode = aDecoder.decodeString(forKey: "mode"), !mode.isEmpty {
			self.mode = QBEExplodeMode.create(identifier: mode, defaultSeparator: aDecoder.decodeString(forKey: "separator") ?? Pack.separator)
		}
		else {
			if let sep = aDecoder.decodeString(forKey: "separator") {
				self.mode = .separator(sep)
			}
			else {
				self.mode = .pack
			}
		}

		super.init(coder: aDecoder)
	}

	override func encode(with coder: NSCoder) {
		let targetNames = self.targetColumns.map { return $0.name }
		coder.encodeString(self.splitColumn.name, forKey: "splitColumn")
		coder.encode(targetNames, forKey: "targetColumns")

		coder.encodeString(self.mode.identifier, forKey: "mode")
		if case .separator(let sep) = self.mode {
			coder.encodeString(sep, forKey: "separator")
		}

		super.encode(with: coder)
	}

	override func apply(_ data: Dataset, job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		callback(.success(StreamDataset(source: QBEExplodeHorizontallyTransformer(source: data.stream(), splitColumn: self.splitColumn, mode: self.mode, targetColumns: self.targetColumns))))
	}
}

