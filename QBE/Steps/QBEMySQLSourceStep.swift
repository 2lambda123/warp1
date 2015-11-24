import Foundation
import WarpCore

/** 
Implementation of the MySQL 'SQL dialect'. Only deviatons from the standard dialect are implemented here. */
private final class QBEMySQLDialect: QBEStandardSQLDialect {
	override var identifierQualifier: String { get { return  "`" } }
	override var identifierQualifierEscape: String { get { return  "\\`" } }
	
	override func unaryToSQL(type: QBEFunction, args: [String]) -> String? {
		let value = args.joinWithSeparator(", ")
		
		if type == QBEFunction.Random {
			return "RAND(\(value))"
		}
		return super.unaryToSQL(type, args: args)
	}
	
	private override func aggregationToSQL(aggregation: QBEAggregation, alias: String) -> String? {
		// For QBEFunction.Count, we should count numeric values only. In MySQL this can be done using REGEXP
		if aggregation.reduce == QBEFunction.Count {
			if let expressionSQL = expressionToSQL(aggregation.map, alias: alias) {
				return "SUM(CASE WHEN (\(expressionSQL) REGEXP '^[[:digit:]]+$') THEN 1 ELSE 0 END)"
			}
			return nil
		}
		
		return super.aggregationToSQL(aggregation, alias: alias)
	}
	
	private override func forceStringExpression(expression: String) -> String {
		return "CAST(\(expression) AS BINARY)"
	}
	
	private override func forceNumericExpression(expression: String) -> String {
		return "CAST(\(expression) AS DECIMAL)"
	}
}

internal final class QBEMySQLResult: SequenceType, GeneratorType {
	typealias Element = QBEFallible<QBETuple>
	typealias Generator = QBEMySQLResult
	
	private let connection: QBEMySQLConnection
	private let result: UnsafeMutablePointer<MYSQL_RES>
	private(set) var columnNames: [QBEColumn] = []
	private(set) var columnTypes: [MYSQL_FIELD] = []
	private(set) var finished = false
	
	static func create(result: UnsafeMutablePointer<MYSQL_RES>, connection: QBEMySQLConnection) -> QBEFallible<QBEMySQLResult> {
		// Get column names from result set
		var resultSet: QBEFallible<QBEMySQLResult> = .Failure("Unknown error")
		
		dispatch_sync(QBEMySQLConnection.sharedQueue) {
			let realResult = QBEMySQLResult(result: result, connection: connection)
			
			let colCount = mysql_field_count(connection.connection)
			for _ in 0..<colCount {
				let column = mysql_fetch_field(result)
				if column != nil {
					if let name = NSString(bytes: column.memory.name, length: Int(column.memory.name_length), encoding: NSUTF8StringEncoding) {
						realResult.columnNames.append(QBEColumn(String(name)))
						realResult.columnTypes.append(column.memory)
					}
					else {
						resultSet = .Failure(NSLocalizedString("The MySQL data contains an invalid column name.", comment: ""))
						return
					}
				}
				else {
					resultSet = .Failure(NSLocalizedString("MySQL returned an invalid column.", comment: ""))
					return
				}
			}
			
			resultSet = .Success(realResult)
		}
		
		return resultSet
	}
	
	private init(result: UnsafeMutablePointer<MYSQL_RES>, connection: QBEMySQLConnection) {
		self.result = result
		self.connection = connection
	}
	
	func finish() {
		_finish(false)
	}
	
	private func _finish(warn: Bool) {
		if !self.finished {
			/* A new query cannot be started before all results from the previous one have been fetched, because packets
			will get out of order. */
			var n = 0
			while self.row() != nil {
				++n
			}
			
			#if DEBUG
				if warn && n > 0 {
					QBELog("Unfinished result was destroyed, drained \(n) rows to prevent packet errors. This is a performance issue!")
				}
			#endif
			self.finished = true
		}
	}
	
	deinit {
		_finish(true)
		
		let result = self.result
		dispatch_sync(QBEMySQLConnection.sharedQueue) {
			mysql_free_result(result)
			return
		}
	}
	
	func generate() -> Generator {
		return self
	}
	
	func next() -> Element? {
		let r = row()
		return r == nil ? nil : .Success(r!)
	}
	
	func row() -> [QBEValue]? {
		var rowData: [QBEValue]? = nil
		
		dispatch_sync(QBEMySQLConnection.sharedQueue) {
			let row: MYSQL_ROW = mysql_fetch_row(self.result)
			if row != nil {
				rowData = []
				rowData!.reserveCapacity(self.columnNames.count)
				
				for cn in 0..<self.columnNames.count {
					let val = row[cn]
					if val == nil {
						rowData!.append(QBEValue.EmptyValue)
					}
					else {
						// Is this a numeric field?
						let type = self.columnTypes[cn]
						if type.type.rawValue == MYSQL_TYPE_TIME.rawValue ||
						 type.type.rawValue == MYSQL_TYPE_DATE.rawValue ||
						 type.type.rawValue == MYSQL_TYPE_DATETIME.rawValue ||
						 type.type.rawValue == MYSQL_TYPE_TIMESTAMP.rawValue {
							
							/* Only MySQL TIMESTAMP values are actual dates in UTC. The rest can be anything, in any time
							zone, so we cannot convert these to QBEValue.DateValue. */
							if let str = String(CString: val, encoding: NSUTF8StringEncoding) {
								if type.type.rawValue == MYSQL_TYPE_TIMESTAMP.rawValue {
									// Datetime string is formatted as YYYY-MM-dd HH:mm:ss and is in UTC
									let dateFormatter = NSDateFormatter()
									dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
									dateFormatter.timeZone = NSTimeZone(abbreviation: "UTC")
									if let d = dateFormatter.dateFromString(str) {
										rowData!.append(QBEValue(d))
									}
									else {
										rowData!.append(QBEValue.InvalidValue)
									}
								}
								else {
									rowData!.append(QBEValue.StringValue(str))
								}
							}
							else {
								rowData!.append(QBEValue.InvalidValue)
							}
						}
						else if (Int32(type.flags) & NUM_FLAG) != 0 {
							if type.type.rawValue == MYSQL_TYPE_TINY.rawValue
								|| type.type.rawValue == MYSQL_TYPE_SHORT.rawValue
								|| type.type.rawValue == MYSQL_TYPE_LONG.rawValue
								|| type.type.rawValue == MYSQL_TYPE_INT24.rawValue
								|| type.type.rawValue == MYSQL_TYPE_LONGLONG.rawValue {
									if let str = String(CString: val, encoding: NSUTF8StringEncoding), let nt = Int(str) {
										rowData!.append(QBEValue.IntValue(nt))
									}
									else {
										rowData!.append(QBEValue.InvalidValue)
									}
									
							}
							else {
								if let str = String(CString: val, encoding: NSUTF8StringEncoding) {
									if let dbl = str.toDouble() {
										rowData!.append(QBEValue.DoubleValue(dbl))
									}
									else {
										rowData!.append(QBEValue.StringValue(str))
									}
								}
								else {
									rowData!.append(QBEValue.InvalidValue)
								}
							}
						}
						else {
							//let value = NSString(bytes: row, length: Int(column.memory.name_length), encoding: NSUTF8StringEncoding);
							if let str = String(CString: val, encoding: NSUTF8StringEncoding) {
								rowData!.append(QBEValue.StringValue(str))
							}
							else {
								rowData!.append(QBEValue.InvalidValue)
							}
						}
					}
				}
			}
			else {
				self.finished = true
			}
		}
		
		return rowData
	}
}

class QBEMySQLDatabase: QBESQLDatabase {
	private let host: String
	private let port: Int
	private let user: String
	private let password: String
	let databaseName: String?
	let dialect: QBESQLDialect = QBEMySQLDialect()
	
	init(host: String, port: Int, user: String, password: String, database: String) {
		self.host = host
		self.port = port
		self.user = user
		self.password = password
		self.databaseName = database
	}
	
	func isCompatible(other: QBEMySQLDatabase) -> Bool {
		return self.host == other.host && self.user == other.user && self.password == other.password && self.port == other.port
	}

	func connect(callback: (QBEFallible<QBESQLConnection>) -> ()) {
		callback(self.connect().use { return $0 })
	}
	
	func connect() -> QBEFallible<QBEMySQLConnection> {
		let connection = QBEMySQLConnection(database: self, connection: mysql_init(nil))
		
		if !connection.perform({ () -> Int32 in
			mysql_real_connect(connection.connection,
				self.host.cStringUsingEncoding(NSUTF8StringEncoding)!,
				self.user.cStringUsingEncoding(NSUTF8StringEncoding)!,
				self.password.cStringUsingEncoding(NSUTF8StringEncoding)!,
				nil,
				UInt32(self.port),
				UnsafePointer<Int8>(nil),
				UInt(0)
			)
			return Int32(mysql_errno(connection.connection))
		}) {
			return .Failure(connection.lastError)
		}
		
		if let dbn = databaseName, let dbc = dbn.cStringUsingEncoding(NSUTF8StringEncoding) where !dbn.isEmpty {
			if !connection.perform({() -> Int32 in
				return mysql_select_db(connection.connection, dbc)
			}) {
				return .Failure(connection.lastError)
			}
		}
		
		/* Use UTF-8 for any textual data that is sent or received in this connection
		(see https://dev.mysql.com/doc/refman/5.0/en/charset-connection.html) */
		connection.query("SET NAMES 'utf8' ").maybe { (res) -> () in
			// We're not using the response from this query
			res.finish()
		}
		
		// Use UTC for any dates that are sent and received in this connection
		connection.query("SET time_zone = '+00:00' ").maybe { (res) -> () in
			// We're not using the response from this query
			res.finish()
		}
		return .Success(connection)
	}

	func dataForTable(table: String, schema: String?, job: QBEJob, callback: (QBEFallible<QBEData>) -> ()) {
		switch QBEMySQLData.create(self, tableName: table) {
		case .Success(let md):
			callback(.Success(md))
		case .Failure(let e):
			callback(.Failure(e))
		}
	}
}

/**
Implements a connection to a MySQL database (corresponding to a MYSQL object in the MySQL library). The connection ensures
that any operations are serialized (for now using a global queue for all MySQL operations). */
internal class QBEMySQLConnection: QBESQLConnection {
	private(set) var database: QBEMySQLDatabase
	private var connection: UnsafeMutablePointer<MYSQL>
	private(set) weak var result: QBEMySQLResult?
	
	// TODO: make this a per-connection queue if the library is thread-safe per connection
	class var sharedQueue : dispatch_queue_t {
		struct Static {
			static var onceToken : dispatch_once_t = 0
			static var instance : dispatch_queue_t? = nil
		}
		dispatch_once(&Static.onceToken) {
			/* Mysql_library_init is what we should call, but as it is #defined to mysql_server_init, Swift doesn't see it. 
			So we just call mysql_server_int. */
			if mysql_server_init(0, nil, nil) == 0 {
				Static.instance = dispatch_queue_create("QBEMySQLConnection.Queue", DISPATCH_QUEUE_SERIAL)
				dispatch_set_target_queue(Static.instance, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0))
			}
			else {
				QBELog("Error initializing MySQL library")
			}
		}
		return Static.instance!
	}
	
	private init(database: QBEMySQLDatabase, connection: UnsafeMutablePointer<MYSQL>) {
		self.database = database
		self.connection = connection
	}
	
	deinit {
		if connection != nil {
			dispatch_sync(QBEMySQLConnection.sharedQueue) {
				mysql_close(self.connection)
			}
		}
	}

	func run(sql: [String], job: QBEJob, callback: (QBEFallible<Void>) -> ()) {
		for query in sql {
			switch self.query(query) {
			case .Success(_):
				break

			case .Failure(let e):
				callback(.Failure(e))
				return
			}
		}

		callback(.Success())
	}

	func clone() -> QBEFallible<QBEMySQLConnection> {
		return self.database.connect()
	}

	/** Fetches the server information string (containing version number and other useful information). This is mostly
	used to check whether a connection can be made. */
	func serverInformation(callback: (QBEFallible<String>) -> ()) {
		switch self.query("SELECT version()") {
		case .Success(let result):
			if let row = result.row() {
				if let version = row.first?.stringValue {
					callback(.Success(version))
				}
				else {
					callback(.Failure("No or invalid version string returned"))
				}
			}
			else {
				callback(.Failure("No version returned"))
			}

		case .Failure(let e): callback(.Failure(e))
		}
	}

	func databases(callback: (QBEFallible<[String]>) -> ()) {
		let resultFallible = self.query("SHOW DATABASES")
		switch resultFallible {
			case .Success(let result):
				var dbs: [String] = []
				while let d = result.row() {
					if let name = d[0].stringValue {
						dbs.append(name)
					}
				}
				
				callback(.Success(dbs))
			
			case .Failure(let error):
				callback(.Failure(error))
		}
	}
	
	func tables(callback: (QBEFallible<[String]>) -> ()) {
		let fallibleResult = self.query("SHOW TABLES")
		switch fallibleResult {
			case .Success(let result):
				var dbs: [String] = []
				while let d = result.row() {
					if let name = d[0].stringValue {
						dbs.append(name)
					}
				}
				callback(.Success(dbs))
			
			case .Failure(let error):
				callback(.Failure(error))
		}
	}
	
	private func perform(block: () -> (Int32)) -> Bool {
		var success: Bool = false
		dispatch_sync(QBEMySQLConnection.sharedQueue) {
			let result = block()
			if result != 0 {
				let message = String(CString: mysql_error(self.connection), encoding: NSUTF8StringEncoding) ?? "(unknown)"
				QBELog("MySQL perform error: \(message)")
				success = false
			}
			else {
				success = true
			}
		}
		return success
	}
	
	private var lastError: String { get {
		return String(CString: mysql_error(self.connection), encoding: NSUTF8StringEncoding) ?? "(unknown)"
	} }
	
	func query(sql: String) -> QBEFallible<QBEMySQLResult> {
		if self.result != nil && !self.result!.finished {
			fatalError("Cannot start a query when the previous result is not finished yet")
		}
		self.result = nil
		
		#if DEBUG
			QBELog("MySQL Query \(sql)")
		#endif

		if self.perform({return mysql_query(self.connection, sql.cStringUsingEncoding(NSUTF8StringEncoding)!)}) {
			let result = QBEMySQLResult.create(mysql_use_result(self.connection), connection: self)
			return result.use({self.result = $0; return .Success($0)})
		}
		else {
			return .Failure(self.lastError)
		}
	}
}

/** 
Represents the result of a MySQL query as a QBEData object. */
final class QBEMySQLData: QBESQLData {
	private let database: QBEMySQLDatabase
	
	static func create(database: QBEMySQLDatabase, tableName: String) -> QBEFallible<QBEMySQLData> {
		let query = "SELECT * FROM \(database.dialect.tableIdentifier(tableName, schema: nil, database: database.databaseName)) LIMIT 1"
		
		let fallibleConnection = database.connect()
		switch fallibleConnection {
			case .Success(let connection):
				let fallibleResult = connection.query(query)
				
				switch fallibleResult {
					case .Success(let result):
						result.finish() // We're not interested in that one row we just requested, just the column names
						return .Success(QBEMySQLData(database: database, table: tableName, columns: result.columnNames))
					
					case .Failure(let error):
						return .Failure(error)
				}
			
			case .Failure(let error):
				return .Failure(error)
		}
	}
	
	private init(database: QBEMySQLDatabase, fragment: QBESQLFragment, columns: [QBEColumn]) {
		self.database = database
		super.init(fragment: fragment, columns: columns)
	}
	
	private init(database: QBEMySQLDatabase, table: String, columns: [QBEColumn]) {
		self.database = database
		super.init(table: table, schema: nil, database: database.databaseName!, dialect: database.dialect, columns: columns)
	}
	
	override func apply(fragment: QBESQLFragment, resultingColumns: [QBEColumn]) -> QBEData {
		return QBEMySQLData(database: self.database, fragment: fragment, columns: resultingColumns)
	}
	
	override func stream() -> QBEStream {
		return QBEMySQLStream(data: self)
	}
	
	private func result() -> QBEFallible<QBEMySQLResult> {
		return self.database.connect().use { $0.query(self.sql.sqlSelect(nil).sql) }
	}
	
	override func isCompatibleWith(other: QBESQLData) -> Bool {
		if let om = other as? QBEMySQLData {
			if self.database.isCompatible(om.database) {
				return true
			}
		}
		return false
	}
}

/**
QBEMySQLStream provides a stream of records from a MySQL result set. Because SQLite result can only be accessed once
sequentially, cloning of this stream requires re-executing the query. */
private final class QBEMySQLResultStream: QBESequenceStream {
	init(result: QBEMySQLResult) {
		super.init(AnySequence<QBEFallible<QBETuple>>(result), columnNames: result.columnNames)
	}
	
	override func clone() -> QBEStream {
		fatalError("QBEMySQLResultStream cannot be cloned, because a result cannot be iterated multiple times. Clone QBEMySQLStream instead")
	}
}

/** 
Stream that lazily queries and streams results from a MySQL query. */
final class QBEMySQLStream: QBEStream {
	private var resultStream: QBEStream?
	private let data: QBEMySQLData
	private let mutex = QBEMutex()
	
	init(data: QBEMySQLData) {
		self.data = data
	}
	
	private func stream() -> QBEStream {
		return self.mutex.locked {
			if resultStream == nil {
				switch data.result() {
					case .Success(let result):
						resultStream = QBEMySQLResultStream(result: result)
					
					case .Failure(let error):
						resultStream = QBEErrorStream(error)
				}
			}
			
			return resultStream!
		}
	}
	
	func fetch(job: QBEJob, consumer: QBESink) {
		return stream().fetch(job, consumer: consumer)
	}
	
	func columnNames(job: QBEJob, callback: (QBEFallible<[QBEColumn]>) -> ()) {
		return stream().columnNames(job, callback: callback)
	}
	
	func clone() -> QBEStream {
		return QBEMySQLStream(data: data)
	}
}

class QBEMySQLSourceStep: QBEStep {
	var tableName: String = ""
	var host: String = "localhost"
	var user: String = "root"
	var databaseName: String = "mysql"
	var port: Int = 3306

	var password: QBESecret {
		return QBESecret(serviceType: "mysql", host: host, port: port, account: user, friendlyName: String(format: NSLocalizedString("User %@ at MySQL server %@ (port %d)", comment: ""), user, host, port))
	}
	
	init(host: String, port: Int, user: String, database: String, tableName: String) {
		self.host = host
		self.user = user
		self.port = port
		self.databaseName = database
		self.tableName = tableName
		super.init()
	}
	
	required init(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)

		let host = (aDecoder.decodeObjectForKey("host") as? String) ?? self.host
		let user = (aDecoder.decodeObjectForKey("user") as? String) ?? self.user
		let port = Int(aDecoder.decodeIntForKey("port"))

		if let pw = aDecoder.decodeStringForKey("password") {
			self.password.stringValue = pw
		}

		self.tableName = (aDecoder.decodeObjectForKey("tableName") as? String) ?? self.tableName
		self.databaseName = (aDecoder.decodeObjectForKey("database") as? String) ?? self.databaseName
		self.user = user
		self.host = host
		self.port = port
	}

	required init() {
	    super.init()
	}
	
	override func encodeWithCoder(coder: NSCoder) {
		super.encodeWithCoder(coder)
		coder.encodeObject(tableName, forKey: "tableName")
		coder.encodeObject(host, forKey: "host")
		coder.encodeObject(user, forKey: "user")
		coder.encodeObject(databaseName, forKey: "database")
		coder.encodeInt(Int32(port ?? 0), forKey: "port")
	}

	override func sentence(locale: QBELocale, variant: QBESentenceVariant) -> QBESentence {
		let template: String
		switch variant {
		case .Neutral, .Read: template = "Load table [#] from MySQL database [#]"
		case .Write: template = "Write to table [#] in MySQL database [#]"
		}

		return QBESentence(format: NSLocalizedString(template, comment: ""),
			QBESentenceList(value: self.tableName ?? "", provider: { (callback) -> () in
				if let d = self.database {
					switch d.connect() {
					case .Success(let con):
						con.tables { tablesFallible in
							switch tablesFallible {
							case .Success(let tables):
								callback(.Success(tables))

							case .Failure(let e):
								callback(.Failure(e))
							}
						}

					case .Failure(let e):
						callback(.Failure(e))
					}
				}
				else {
					callback(.Failure(NSLocalizedString("Could not connect to database", comment: "")))
				}
				}, callback: { (newTable) -> () in
					self.tableName = newTable
			}),

			QBESentenceList(value: self.databaseName ?? "", provider: { (callback) -> () in
				if let d = self.database {
					switch d.connect() {
					case .Success(let con):
						con.databases { dbFallible in
							switch dbFallible {
								case .Success(let dbs):
									callback(.Success(dbs))

								case .Failure(let e):
									callback(.Failure(e))
							}
						}

					case .Failure(let e):
						callback(.Failure(e))
					}
				}
				else {
					callback(.Failure(NSLocalizedString("Could not connect to database", comment: "")))
				}
			}, callback: { (newDatabase) -> () in
				self.databaseName = newDatabase
			})
		)
	}
	
	internal var database: QBEMySQLDatabase? { get {
		/* For MySQL, the hostname 'localhost' is special and indicates access through a local UNIX socket. This does
		not work from a sandboxed application unless special privileges are obtained. To avoid confusion we rewrite
		localhost here to 127.0.0.1 in order to force access through TCP/IP. */
		let ha = (host == "localhost") ? "127.0.0.1" : host
		return QBEMySQLDatabase(host: ha, port: port, user: user, password: password.stringValue ?? "", database: databaseName)
	} }

	override var mutableData: QBEMutableData? { get {
		if let s = self.database where !self.tableName.isEmpty {
			return QBESQLMutableData(database: s, schemaName: nil, tableName: self.tableName)
		}
		return nil
	} }

	var warehouse: QBEDataWarehouse? {
		if let s = self.database where !self.tableName.isEmpty {
			return QBESQLDataWarehouse(database: s, schemaName: nil)
		}
		return nil
	}

	override func fullData(job: QBEJob, callback: (QBEFallible<QBEData>) -> ()) {
		job.async {
			if let s = self.database {
				let md = QBEMySQLData.create(s, tableName: self.tableName ?? "")
				callback(md.use { $0.coalesced })
			}
			else {
				callback(.Failure(NSLocalizedString("Could not connect to the MySQL database.", comment: "")))
			}
		}
	}
	
	override func exampleData(job: QBEJob, maxInputRows: Int, maxOutputRows: Int, callback: (QBEFallible<QBEData>) -> ()) {
		self.fullData(job, callback: { (fd) -> () in
			callback(fd.use({$0.random(maxInputRows)}))
		})
	}
}