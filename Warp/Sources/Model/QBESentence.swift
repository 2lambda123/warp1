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

public protocol QBESubSentence {
}

extension String {
	var localized: String {
		return NSLocalizedString(self, comment: "")
	}
}

/** A sentence is a string of tokens that describe the action performed by a step in natural language, and allow for the
configuration of that step. For example, a step that limits the number of rows in a result set may have a sentence like
"limit to [x] rows". In this case, the sentence consists of three tokens: a constant text ('limit to'), a configurable
number token ('x') and another constant text ('rows'). */
public class QBESentence: QBESubSentence {
	public private(set) var tokens: [QBESentenceToken]

	public init(_ tokens: [QBESentenceToken] = []) {
		self.tokens = tokens
	}

	public static let formatStringTokenPlaceholder = "[#]"

	/** Create a sentence based on a formatting string and a set of tokens. This allows for flexible localization of
	sentences. The format string may contain instances of '[#]' as placeholders for tokens. This is the preferred way
	of constructing sentences, since it allows for proper localization (word order may be different between languages).*/
	public init(format: String, _ tokens: QBESubSentence...) {
		self.tokens = []

		var startIndex = format.startIndex
		for token in tokens {
			if let nextToken = format.range(of: QBESentence.formatStringTokenPlaceholder, options: [], range: startIndex..<format.endIndex) {
				let constantString = String(format[startIndex..<nextToken.lowerBound])
				self.tokens.append(QBESentenceLabelToken(constantString))

				if let s = token as? QBESentence {
					self.tokens.append(contentsOf: s.tokens)
				}
				else if let t = token as? QBESentenceToken {
					self.tokens.append(t)
				}
				else {
					fatalError("Unrecognized subsentence type")
				}

				startIndex = nextToken.upperBound
			}
			else {
				fatalError("There are more tokens than there can be placed in the format string '\(format)'")
			}
		}

		if format.distance(from: startIndex, to: format.endIndex) > 0 {
			self.tokens.append(QBESentenceLabelToken(String(format[startIndex..<format.endIndex])))
		}

		self.tokens = self.sanitizedTokens
	}

	/** NSTokenField will put a comma between two text tokens, we want that to be spaces. This merges successive text tokens. */
	private var sanitizedTokens: [QBESentenceToken] {
		var newTokens: [QBESentenceToken] = []

		for token in self.tokens {
			if let last = newTokens.last, token is QBESentenceLabelToken && last is QBESentenceLabelToken {
				newTokens.removeLast()
				let newToken = QBESentenceLabelToken(last.label + token.label)
				newTokens.append(newToken)
			}
			else {
				newTokens.append(token)
			}
		}
		return newTokens
	}

	public func append(_ sentence: QBESentence) {
		self.tokens.append(contentsOf: sentence.tokens)
	}

	public func append(_ token: QBESentenceToken) {
		self.tokens.append(token)
	}

	public var stringValue: String { get {
		return self.tokens.map({ return $0.label }).joined(separator: "")
		} }
}

public protocol QBESentenceToken: NSObjectProtocol, QBESubSentence {
	var label: String { get }
	var isToken: Bool { get }
}

/** A sentence item that presents a list of (string) options. */
public class QBESentenceDynamicOptionsToken: NSObject, QBESentenceToken {
	public typealias Callback = (String) -> ()
	public typealias ProviderCallback = (Fallible<[String]>) -> ()
	public typealias Provider = (@escaping ProviderCallback) -> ()
	public private(set) var optionsProvider: Provider
	private(set) var value: String
	public let callback: Callback

	public var label: String { get {
		return value
		} }

	public init(value: String, provider: @escaping Provider, callback: @escaping Callback) {
		self.optionsProvider = provider
		self.value = value
		self.callback = callback
	}

	public var isToken: Bool { get { return true } }

	public func select(_ key: String) {
		if key != value {
			callback(key)
			self.value = key
		}
	}
}

/** A sentence item that shows a list of string options, which have associated string keys. */
public class QBESentenceOptionsToken: NSObject, QBESentenceToken {
	public typealias Callback = (String) -> ()
	public private(set) var options: [String: String]
	public private(set) var value: String
	public let callback: Callback

	public var label: String { get {
		return options[value] ?? ""
	} }

	public init(options: [String: String], value: String, callback: @escaping Callback) {
		self.options = options
		self.value = value
		self.callback = callback
	}

	public var isToken: Bool { get { return true } }

	public func select(_ key: String) {
		assert(options[key] != nil, "Selecting an invalid option")
		if key != value {
			callback(key)
			self.value = key
		}
	}
}

/** A sentence item that shows an editable, ordered list of columns. */
public class QBESentenceColumnsToken: NSObject, QBESentenceToken {
	public typealias Callback = (OrderedSet<Column>) -> ()
	public private(set) var value: OrderedSet<Column>
	public let callback: Callback

	public var label: String {
		if self.value.count > 4 {
			let first = self.value.sorted(by: { $0.name < $1.name }).map { $0.name }.prefix(4)
			return String(format: "%@ and %d more".localized, first.joined(separator: ", "), self.value.count - first.count)
		}

		return self.value.map { $0.name }.joined(separator: ", ")
	}

	public init(value: OrderedSet<Column>, callback: @escaping Callback) {
		self.value = value
		self.callback = callback
	}

	public var isToken: Bool { get { return true } }

	public func select(_ set: OrderedSet<Column>) {
		self.value = set
		callback(set)
	}
}

/** A sentence item that shows a list of string options, which have associated string keys. Either option can be selected
or deselected.*/
public class QBESentenceSetToken: NSObject, QBESentenceToken {
	public typealias Provider = (_ callback: @escaping (Fallible<Set<String>>) -> ()) -> ()
	public typealias Callback = (Set<String>) -> ()
	public private(set) var provider: Provider
	public private(set) var value: Set<String>
	public let callback: Callback

	public var label: String {
		if self.value.count > 4 {
			let first = self.value.sorted().prefix(4)
			return String(format: "%@ and %d more".localized, first.joined(separator: ", "), self.value.count - first.count)
		}

		return self.value.joined(separator: ", ")
	}

	public init(value: Set<String>, provider: @escaping Provider, callback: @escaping Callback) {
		self.provider = provider
		self.value = value
		self.callback = callback
	}

	public var isToken: Bool { get { return true } }

	public func select(_ set: Set<String>) {
		self.value = set
		callback(set)
	}
}

/** Sentence item that shows static, read-only text. */
public class QBESentenceLabelToken: NSObject, QBESentenceToken {
	public let label: String

	public init(_ label: String) {
		self.label = label
	}

	public var isToken: Bool { get { return false } }
}

/** Sentence item that shows editable text. */
public class QBESentenceTextToken: NSObject, QBESentenceToken {
	public typealias Callback = (String) -> (Bool)
	public var label: String
	public let callback: Callback

	public init(value: String, callback: @escaping Callback) {
		self.label = value
		self.callback = callback
	}

	public func change(_ newValue: String) -> Bool {
		if label != newValue {
			if callback(newValue) {
				self.label = newValue
				return true
			}
			return false
		}
		return true
	}

	public var isToken: Bool { get { return true } }
}

public class QBESentenceValueToken: QBESentenceTextToken {
	public typealias ValueCallback = (Value) -> (Bool)

	public init(value: Value, locale: Language, callback: @escaping ValueCallback) {
		super.init(value: locale.localStringFor(value)) { s -> Bool in
			return callback(locale.valueForLocalString(s))
		}
	}
}

public struct QBESentenceFormulaTokenContext {
	var row: Row
	var columns: OrderedSet<Column>
}

/** Sentence item that shows a friendly representation of a formula, and shows a formula editor on editing. */
public class QBESentenceFormulaToken: NSObject, QBESentenceToken {
	public typealias ContextCallback = (Fallible<QBESentenceFormulaTokenContext>) -> ()
	public typealias ContextProviderCallback = (Job, @escaping ContextCallback) -> ()
	public typealias Callback = (Expression) -> ()
	public var expression: Expression
	public let locale: Language
	public let callback: Callback // Called when a new formula is set
	public let contextCallback: ContextProviderCallback? // Called to obtain context information (columns, example row, etc.)

	public init(expression: Expression, locale: Language, callback: @escaping Callback, contextCallback: ContextProviderCallback? = nil) {
		self.expression = expression
		self.locale = locale
		self.callback = callback
		self.contextCallback = contextCallback
	}

	@discardableResult public func change(_ newValue: Expression) -> Bool {
		if !self.expression.isEqual(newValue) {
			self.expression = newValue
			callback(newValue)
			return true
		}
		return false
	}

	public var label: String {
		get {
			return expression.explain(self.locale, topLevel: true)
		}
	}

	public var isToken: Bool { get { return true } }
}

public enum QBESentenceFileTokenMode {
	case writing
	case reading(canCreate: Bool)
}

/** Sentence item that refers to an (existing or yet to be created) file or directory. */
public class QBESentenceFileToken: NSObject, QBESentenceToken {
	public typealias Callback = (QBEFileReference) -> ()
	public let file: QBEFileReference?
	public let allowedFileTypes: [String]
	public let callback: Callback
	public let isDirectory: Bool
	public let mode: QBESentenceFileTokenMode

	public init(directory: QBEFileReference?, callback: @escaping Callback) {
		self.allowedFileTypes = []
		self.file = directory
		self.callback = callback
		self.isDirectory = true
		self.mode = .reading(canCreate: true)
	}

	public init(saveFile file: QBEFileReference?, allowedFileTypes: [String], callback: @escaping Callback) {
		self.file = file
		self.callback = callback
		self.allowedFileTypes = allowedFileTypes
		self.isDirectory = false
		self.mode = .writing
	}

	public init(file: QBEFileReference?, allowedFileTypes: [String], canCreate: Bool = false, callback: @escaping Callback) {
		self.file = file
		self.callback = callback
		self.allowedFileTypes = allowedFileTypes
		self.isDirectory = false
		self.mode = .reading(canCreate: canCreate)
	}

	public func change(_ newValue: QBEFileReference) {
		callback(newValue)
	}

	public var label: String {
		get {
			return file?.url?.lastPathComponent ?? NSLocalizedString("(no file)", comment: "")
		}
	}

	public var isToken: Bool { get { return true } }
}

extension QBEStep {
	func contextCallbackForFormulaSentence(_ job: Job, callback: @escaping QBESentenceFormulaToken.ContextCallback) {
		if let sourceStep = self.previous {
			sourceStep.exampleDataset(job, maxInputRows: 100, maxOutputRows: 1) { result in
				switch result {
				case .success(let data):
					data.limit(1).raster(job) { result in
						switch result {
						case .success(let raster):
							if raster.rowCount == 1 {
								let ctx = QBESentenceFormulaTokenContext(row: raster[0], columns: raster.columns)
								return callback(.success(ctx))
							}

						case .failure(let e):
							return callback(.failure(e))
						}
					}

				case .failure(let e):
					return callback(.failure(e))
				}
			}
		}
		else {
			return callback(.failure("No data source for chart".localized))
		}
	}
}
