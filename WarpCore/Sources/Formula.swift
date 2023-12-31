/* Copyright (c) 2014-2016 Pixelspark, Tommy van der Vorst

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */
import Foundation
import SwiftParser

/** Formula parses formulas written down in an Excel-like syntax (e.g. =SUM(SQRT(1+2/3);IF(1>2;3;4))) as a Expression
that can be used to calculate values. Like in Excel, the language used for the formulas (e.g. for function names) depends
on the user's preference and is therefore variable (Language implements this). */
public class Formula: Parser {
	/** The character that indicates a formula starts. While it is not required in the formula syntax, it can be used to 
	distinguish text and other static data from formulas. **/
	public static let prefix = "="

	public struct Fragment {
		public let start: Int
		public let end: Int
		public let expression: Expression
		
		public var length: Int {
			return end - start
		}
	}

	let locale: Language
	public let originalText: String
	public private(set) var fragments: [Fragment] = []

	private var stack = Stack<Expression>()
	private var callStack = Stack<CallSite>()
	private var error: Bool = false
	
	public init?(formula: String, locale: Language) {
		self.originalText = formula
		self.locale = locale
		self.fragments = []
		super.init()
		self.grammar = self.rules()
		do {
			_ = try self.parse(formula)
		}
		catch {
			return nil
		}

		if self.error || self.stack.items.isEmpty {
			return nil
		}
		super.captures.removeAll(keepingCapacity: false)
	}

	public var root: Expression {
		return stack.head
	}
	
	private func annotate(_ expression: Expression) {
		if let cc = super.currentCapture {
			fragments.append(Fragment(start: cc.start, end: cc.end, expression: expression))
		}
	}
	
	private func pushInt() {
		if let n = self.locale.numberFormatter.number(from: self.text.replacingOccurrences(of: self.locale.groupingSeparator, with: "")) {
			annotate(stack.push(Literal(Value.int(n.intValue))))
		}
		else {
			annotate(stack.push(Literal(Value.invalid)))
			error = true
		}
	}
	
	private func pushDouble() {
		if let n = self.locale.numberFormatter.number(from: self.text.replacingOccurrences(of: self.locale.groupingSeparator, with: "")) {
			annotate(stack.push(Literal(Value.double(n.doubleValue))))
		}
		else {
			annotate(stack.push(Literal(Value.invalid)))
			error = true
		}
	}
	
	private func pushTimestamp() {
        let ts = self.text[self.text.index(self.text.startIndex, offsetBy: 1)...]
        if let n = self.locale.numberFormatter.number(from: String(ts)) {
			annotate(stack.push(Literal(Value.date(n.doubleValue))))
		}
		else {
			annotate(stack.push(Literal(Value.invalid)))
		}
	}
	
	private func pushString() {
		let text = self.text.replacingOccurrences(of: "\"\"", with: "\"")
		annotate(stack.push(Literal(Value(text))))
	}

	private func pushBlob() {
		if let data = Data(base64Encoded: self.text) {
			annotate(stack.push(Literal(Value.blob(data))))
		}
		else {
			annotate(stack.push(Literal(Value.invalid)))
		}
	}
	
	private func pushAddition() {
		pushBinary(Binary.addition)
	}
	
	private func pushSubtraction() {
		pushBinary(Binary.subtraction)
	}
	
	private func pushMultiplication() {
		pushBinary(Binary.multiplication)
	}

	private func pushModulus() {
		pushBinary(Binary.modulus)
	}
	
	private func pushDivision() {
		pushBinary(Binary.division)
	}
	
	private func pushPower() {
		pushBinary(Binary.power)
	}
	
	private func pushConcat() {
		pushBinary(Binary.concatenation)
	}
	
	private func pushNegate() {
		let a = stack.pop()
		stack.push(Call(arguments: [a], type: Function.negate));
	}
	
	private func pushSibling() {
		annotate(stack.push(Sibling(Column(self.text))))
	}
	
	private func pushForeign() {
		annotate(stack.push(Foreign(Column(self.text))))
	}
	
	private func pushConstant() {
		for (constant, name) in locale.constants {
			if name.caseInsensitiveCompare(self.text) == ComparisonResult.orderedSame {
				annotate(stack.push(Literal(constant)))
				return
			}
		}
	}

	private func pushPostfixMultiplier(_ factor: Value) {
		let a = stack.pop()
		annotate(stack.push(Comparison(first: Literal(factor), second: a, type: Binary.multiplication)))
	}
	
	private func pushBinary(_ type: Binary) {
		let a = stack.pop()
		let b = stack.pop()
		stack.push(Comparison(first:a, second: b, type: type))
	}

	private func pushIndex() {
		let a = stack.pop()
		let b = stack.pop()
		stack.push(Call(arguments: [b, a], type: .nth))
	}

	private func pushValueForKey() {
		let a = stack.pop()
		let b = stack.pop()
		stack.push(Call(arguments: [b, a], type: .valueForKey))
	}
	
	private func pushGreater() {
		pushBinary(Binary.greater)
	}
	
	private func pushGreaterEqual() {
		pushBinary(Binary.greaterEqual)
	}
	
	private func pushLesser() {
		pushBinary(Binary.lesser)
	}
	
	private func pushLesserEqual() {
		pushBinary(Binary.lesserEqual)
	}
	
	private func pushContainsString() {
		pushBinary(Binary.containsString)
	}
	
	private func pushContainsStringStrict() {
		pushBinary(Binary.containsStringStrict)
	}
	
	private func pushEqual() {
		pushBinary(Binary.equal)
	}
	
	private func pushNotEqual() {
		pushBinary(Binary.notEqual)
	}
	
	private func pushCall() {
		if let qu = locale.functionWithName(self.text) {
			callStack.push(CallSite(function: qu))
			return
		}
		
		// This should not happen
		fatalError("Parser rule lead to pushing a function that doesn't exist!")
	}
	
	private func pushIdentity() {
		annotate(stack.push(Identity()))
	}
	
	private func popCall() {
		let q = callStack.pop()
		annotate(stack.push(Call(arguments: q.args, type: q.function)))
	}
	
	private func pushArgument() {
		let q = stack.pop()
		var call = callStack.pop()
		call.args.append(q)
		callStack.push(call)
	}

	private func pushList() {
		callStack.push(CallSite(function: .list))
	}

	private func popList() {
		self.popCall()
	}

	/** Shorthand sibling notation: alphanumeric characters and underscore only, must start with alphabetic character. */
	public static func shorthandSiblingRule() -> ParserRule {
		let firstCharacter: ParserRule = (("a"-"z")|("A"-"Z"))
		let followingCharacter: ParserRule = (firstCharacter | ("0"-"9") | literal("_"))

		return (firstCharacter ~~ followingCharacter*)
	}

	public static func canBeWittenAsShorthandSibling(name: String) -> Bool {
		let parserRule = (Formula.shorthandSiblingRule() ~ Parser.matchEOF())
		let grammar = Grammar()
		grammar.startRule = parserRule
		do {
			return try Parser(grammar: grammar).parse(name)
		}
		catch {
			return false
		}
	}

	private func rules() -> Grammar {
		/* We need to sort the function names by length (longest first) to make sure the right one gets matched. If the 
		shorter functions come first, they match with the formula before we get a chance to see whether the longer one 
		would also match  (parser is dumb) */
		var functionRules: [ParserRule] = []
		let functionNames = Function.allFunctions
			.map({ return self.locale.nameForFunction($0) ?? "" })
			.sorted(by: { (a,b) in return a.count > b.count})
		
		functionNames.forEach {(functionName) in
			if !functionName.isEmpty {
				functionRules.append(Parser.matchLiteralInsensitive(functionName))
			}
		}

		let postfixRules = locale.postfixes.map { (postfix, multiplier) in return (literal(postfix) => { [unowned self] in self.pushPostfixMultiplier(multiplier) }) }

		let grammar = Grammar();

		func add_named_rule(_ name: String, rule: ParserRule) {
			grammar[name] = rule;
		}
		
		// String literals & constants
		add_named_rule("list",				rule: (((literal("{") => pushList) ~~ Parser.matchList(^"logic" => pushArgument, separator: literal(locale.argumentSeparator)) ~~ "}")) => popList)
		add_named_rule("arguments",			rule: (("(" ~~ Parser.matchList(^"logic" => pushArgument, separator: literal(locale.argumentSeparator)) ~~ ")")))
		add_named_rule("unaryFunction",		rule: ((Parser.matchAnyFrom(functionRules) => pushCall) ~~ ^"arguments") => popCall)
		add_named_rule("constant",			rule: Parser.matchAnyFrom(locale.constants.values.map({Parser.matchLiteralInsensitive($0)})) => pushConstant)
		add_named_rule("stringLiteral",		rule: literal(String(locale.stringQualifier)) ~ ((Parser.matchAnyCharacterExcept([locale.stringQualifier]) | locale.stringQualifierEscape)* => pushString) ~ literal(String(locale.stringQualifier)))
		add_named_rule("blobLiteral",		rule: literal(String(locale.blobQualifier)) ~ ((Parser.matchAnyCharacterExcept([locale.blobQualifier]))* => pushBlob) ~ literal(String(locale.blobQualifier)))
		
		add_named_rule("currentCell",		rule: literal(locale.currentCellIdentifier) => pushIdentity)
		
		add_named_rule("sibling",			rule: literal(String(locale.siblingQualifiers.0)) ~ (Parser.matchAnyCharacterExcept([locale.siblingQualifiers.1])* => pushSibling) ~ literal(String(locale.siblingQualifiers.1)))
		add_named_rule("siblingSimple",		rule: Formula.shorthandSiblingRule() => pushSibling)
		add_named_rule("foreignSimple",		rule: literal(String(locale.foreignModifier)) ~ (Formula.shorthandSiblingRule() => pushForeign))
		add_named_rule("foreign",			rule: literal(String(locale.foreignModifier)) ~ literal(String(locale.siblingQualifiers.0)) ~  (Parser.matchAnyCharacterExcept([locale.siblingQualifiers.1])+ => pushForeign) ~ literal(String(locale.siblingQualifiers.1)))
		add_named_rule("subexpression",		rule: (("(" ~~ (^"logic") ~~ ")")))
		
		// Number literals
		add_named_rule("digits",			rule: (("0"-"9") | locale.groupingSeparator)+)
		add_named_rule("numberPostfix",		rule: Parser.matchAnyFrom(postfixRules)/~)
		add_named_rule("timestamp",			rule: ("@" ~ ^"digits" ~ (locale.decimalSeparator ~ ^"digits")/~) => pushTimestamp)
		add_named_rule("doubleNumber",		rule: ((^"digits" ~ locale.decimalSeparator ~ ^"digits") => pushDouble) | ((^"digits") => pushInt))
		add_named_rule("negativeNumber",	rule: ("-" ~ ^"doubleNumber") => pushNegate)
		add_named_rule("postfixedNumber",	rule: (^"negativeNumber" | ^"doubleNumber") ~ ^"numberPostfix")
		add_named_rule("value",				rule: ^"postfixedNumber" | ^"timestamp" | ^"stringLiteral" | ^"blobLiteral" | ^"unaryFunction" | ^"currentCell" | ^"constant" | ^"siblingSimple" | ^"foreignSimple" | ^"sibling" | ^"foreign" | ^"list" | ^"subexpression")


		add_named_rule("indexer",			rule: ((("[" ~~ ^"value" ~~ "]") => pushIndex) | (("->" ~~ ^"value") => pushValueForKey)))
		add_named_rule("indexedValue",		rule: ^"value" ~~ ((^"indexer")*))
		add_named_rule("exponent",			rule: ^"indexedValue" ~~ (("^" ~~ ^"indexedValue") => pushPower)*)

		let factor = ^"exponent" ~~ ((("*" ~~ ^"exponent") => pushMultiplication) | (("/" ~~ ^"exponent") => pushDivision) | (("~" ~~ ^"exponent") => pushModulus))*
		let addition = factor ~~ (("+" ~~ factor => pushAddition) | ("-" ~~ factor => pushSubtraction))*

		add_named_rule("concatenation",		rule: addition ~~ (("&" ~~ addition) => pushConcat)*)
		
		// Comparisons
		add_named_rule("containsString",	rule: ("~=" ~~ ^"concatenation") => pushContainsString)
		add_named_rule("containsStringStrict", rule: ("~~=" ~~ ^"concatenation") => pushContainsStringStrict)
		add_named_rule("matchesRegex",		rule: ("±=" ~~ ^"concatenation") => { [unowned self] in self.pushBinary(Binary.matchesRegex) })
		add_named_rule("matchesRegexStrict", rule: ("±±=" ~~ ^"concatenation") => { [unowned self] in self.pushBinary(Binary.matchesRegexStrict)})
		add_named_rule("greater",			rule: (">" ~~ ^"concatenation") => pushGreater)
		add_named_rule("greaterEqual",		rule: (">=" ~~ ^"concatenation") => pushGreaterEqual)
		add_named_rule("lesser",			rule: ("<" ~~ ^"concatenation") => pushLesser)
		add_named_rule("lesserEqual",		rule: ("<=" ~~ ^"concatenation") => pushLesserEqual)
		add_named_rule("equal",				rule: ("=" ~~ ^"concatenation") => pushEqual)
		add_named_rule("notEqual",			rule: ("<>" ~~ ^"concatenation") => pushNotEqual)
		add_named_rule("logic",				rule: ^"concatenation" ~~ (^"greaterEqual" | ^"greater" | ^"lesserEqual" | ^"lesser" | ^"equal" | ^"notEqual" | ^"containsString" | ^"containsStringStrict" | ^"matchesRegex" | ^"matchesRegexStrict" )*)

		let formula = (Formula.prefix)/~ ~~ self.whitespace ~~ (^"logic")*!*
		grammar.startRule = formula
		return grammar;
	}

	public var whitespace: ParserRule = (" " | "\t" | "\r\n" | "\r" | "\n")*
}

internal extension Parser {
	static func matchEOF() -> ParserRule {
		return ParserRule({ (parser: Parser, reader: Reader) -> Bool in
			return reader.eof()
		})
	}

	static func matchAnyCharacterExcept(_ characters: [Character]) -> ParserRule {
		return ParserRule({ (parser: Parser, reader: Reader) -> Bool in
			if reader.eof() {
				return false
			}
			
			let pos = reader.position
			let ch = reader.read()
			for exceptedCharacter in characters {
				if ch==exceptedCharacter {
					reader.seek(pos)
					return false
				}
			}
			return true
		})
	}
	
	static func matchAnyFrom(_ rules: [ParserRule]) -> ParserRule {
		return ParserRule({ (parser: Parser, reader: Reader) -> Bool in
			let pos = reader.position
			for rule in rules {
				do {
					if(try rule.matches(parser, reader)) {
						return true
					}
				}
				catch {}
				reader.seek(pos)
			}
			
			return false
		})
	}
	
	static func matchList(_ item: ParserRule, separator: ParserRule) -> ParserRule {
		return item/~ ~~ (separator ~~ item)*
	}
	
	static func matchLiteralInsensitive(_ string:String) -> ParserRule {
		return ParserRule({ (parser: Parser, reader: Reader) -> Bool in
			let pos = reader.position
			
			for ch in string {
				let flag = (String(ch).caseInsensitiveCompare(String(reader.read())) == ComparisonResult.orderedSame)
				
				if !flag {
					reader.seek(pos)
					return false
				}
			}
			return true
		})
	}

	static func matchLiteral(_ string:String) -> ParserRule {
		return ParserRule({ (parser: Parser, reader: Reader) -> Bool in
			let pos = reader.position

			for ch in string {
				if ch != reader.read() {
					reader.seek(pos)
					return false
				}
			}
			return true
		})
	}
}

private struct CallSite {
	let function: Function
	var args: [Expression] = []
	
	init(function: Function) {
		self.function = function
	}
}
