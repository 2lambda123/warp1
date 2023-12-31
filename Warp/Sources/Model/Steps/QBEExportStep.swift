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

class QBEExportStep: QBEStep {
	private(set) var writer: QBEFileWriter? = nil
	private(set) var file: QBEFileReference? = nil

	init(previous: QBEStep?, writer: QBEFileWriter, file: QBEFileReference) {
		super.init(previous: previous)
		self.writer = writer
		self.file = file
	}

	override func encode(with coder: NSCoder) {
		coder.encode(self.writer, forKey: "writer")
		super.encode(with: coder)
	}

	required init(coder aDecoder: NSCoder) {
		self.writer = aDecoder.decodeObject(forKey: "writer") as? QBEFileWriter
		super.init(coder: aDecoder)
	}

	required init() {
		writer = nil
		file = nil
		super.init()
	}

	override func willSaveToDocument(_ atURL: URL) {
		self.file = self.file?.persist(atURL)
	}

	override func didLoadFromDocument(_ atURL: URL) {
		self.file = self.file?.resolve(atURL)
	}

	func write(_ job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		super.fullDataset(job) { (fallibleDataset) -> () in
			switch fallibleDataset {
			case .success(let data):
				if let w = self.writer, let url = self.file?.url {
					job.async {
						w.writeDataset(data, toFile: url, locale: Language(), job: job, callback: { (result) -> () in
							switch result {
							case .success:
								callback(.success(data))

							case .failure(let e):
								callback(.failure(e))
							}
						})
					}
				}
				else {
					callback(.failure("Export is configured incorrectly, or not file to export to"))
				}

			case .failure(let e):
				callback(.failure(e))
			}
		}
	}

	override func fullDataset(_ job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		self.write(job, callback: callback)
	}

	override func apply(_ data: Dataset, job: Job, callback: @escaping (Fallible<Dataset>) -> ()) {
		return callback(.success(data))
	}

	override func sentence(_ locale: Language, variant: QBESentenceVariant) -> QBESentence {
		let factory = QBEFactory.sharedInstance

		// Populate the list of possible file types to export in
		var options: [String: String] = [:]
		var currentKey: String = ""
		for writer in factory.fileWriters {
			if let ext = writer.fileTypes.first {
				let allExtensions = writer.fileTypes.joined(separator: ", ")
				options[ext] = "\(writer.explain(ext, locale: locale)) (\(allExtensions.uppercased()))"
				if let w = self.writer, writer == type(of: w) {
					currentKey = ext
				}
			}
		}

		let s = QBESentence(format: NSLocalizedString("Export data as [#] to [#]", comment: ""),
			QBESentenceOptionsToken(options: options, value: currentKey, callback: { [weak self] (newKey) -> () in
				if let newType = factory.fileWriterForType(newKey) {
					self?.writer = newType.init(locale: locale, title: "")
				}
			}),

			QBESentenceFileToken(saveFile: self.file, allowedFileTypes: Array(factory.fileExtensionsForWriting), callback: { [weak self] (newFile) -> () in
				self?.file = newFile
				if let url = newFile.url {
					let fileExtension = url.pathExtension
					if let w = self?.writer, !type(of: w).fileTypes.contains(fileExtension) {
						if let newWriter = factory.fileWriterForType(fileExtension) {
							self?.writer = newWriter.init(locale: locale, title: "")
						}
					}
				}
			})
		)

		if let writerSentence = self.writer?.sentence(locale) {
			s.append(writerSentence)
		}
		return s
	}
}
