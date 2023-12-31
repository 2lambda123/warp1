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

public class QBEFileAccess {
	private let URL: URL

	fileprivate init(_ URL: URL) {
		self.URL = URL
		if !URL.startAccessingSecurityScopedResource() {
			trace("startAccessingSecurityScopedResource failed for \(URL)")
		}
	}

	deinit {
		trace("stopAccessingSecurityScopedResource for \(URL)")
		URL.stopAccessingSecurityScopedResource()
	}
}

/** QBEFileReference is the class to be used by steps that need to reference auxiliary files. It employs Apple's App
Sandbox API to create 'secure bookmarks' to these files, so that they can be referenced when opening the Warp document
again later. Steps should call bookmark() on all their references from the willSavetoDocument method, and call resolve()
on all file references inside didLoadFromDocument. In addition they should store both the 'url' as well as the 'bookmark'
property when serializing a file reference (in encodeWithCoder).

On non-sandbox builds, QBEFileReference will not be able to resolve bookmarks to URLs, and it will return the original URL
(which will allow regular unlimited access). */
public enum QBEFileReference: Equatable {
	case bookmark(Data)
	case resolvedBookmark(Data, URL, QBEFileAccess)
	case absolute(URL?)

	public static func create(_ url: URL?, _ bookmark: Data?) -> QBEFileReference? {
		if bookmark == nil {
			if url != nil {
				return QBEFileReference.absolute(url!)
			}
			else {
				return nil
			}
		}
		else {
			if url == nil {
				return QBEFileReference.bookmark(bookmark!)
			}
			else {
				return QBEFileReference.resolvedBookmark(bookmark!, url!, QBEFileAccess(url!))
			}
		}
	}

	public func persist(_ relativeToDocument: URL?) -> QBEFileReference? {
		switch self {
		case .absolute(let u):
			do {
				if let url = u {
					#if os(macOS)
					let bookmark = try url.bookmarkData(options: URL.BookmarkCreationOptions.withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: relativeToDocument)
					#endif

					#if os(iOS)
					let bookmark = try url.bookmarkData(options: URL.BookmarkCreationOptions.suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: relativeToDocument)
					#endif

					do {
						var stale: Bool = false
						#if os(macOS)
						let resolved = try URL(resolvingBookmarkData: bookmark, options: URL.BookmarkResolutionOptions.withSecurityScope, relativeTo: relativeToDocument, bookmarkDataIsStale: &stale)
						#endif

						#if os(iOS)
						let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: relativeToDocument, bookmarkDataIsStale: &stale)
						#endif

						if stale {
							trace("Just-created URL bookmark is already stale! \(resolved)")
						}
						return QBEFileReference.resolvedBookmark(bookmark, resolved, QBEFileAccess(resolved))
					}
					catch let error as NSError {
						trace("Failed to resolve just-created bookmark: \(error)")
					}
				}
				return self
			}
			catch let error as NSError {
				trace("Could not create bookmark for url \(String(describing: u)): \(error)")
			}
			return self

		case .bookmark(_):
			return self

		case .resolvedBookmark(_,_,_):
			return self
		}
	}

	public func resolve(_ relativeToDocument: URL?) -> QBEFileReference? {
		switch self {
		case .absolute(_):
			return self

		case .resolvedBookmark(let b, let oldURL, _):
			do {
				var stale = false
				#if os(macOS)
					let u = try URL(resolvingBookmarkData: b, options: URL.BookmarkResolutionOptions.withSecurityScope, relativeTo: relativeToDocument, bookmarkDataIsStale: &stale)
				#endif

				#if os(iOS)
					let u = try URL(resolvingBookmarkData: b, options: [], relativeTo: relativeToDocument, bookmarkDataIsStale: &stale)
				#endif

				if stale {
					trace("Resolved bookmark is stale: \(String(describing: u))")
					return QBEFileReference.absolute(u)
				}

				return QBEFileReference.resolvedBookmark(b, u, QBEFileAccess(u))
			}
			catch let error as NSError {
				trace("Could not re-resolve bookmark \(b) to \(oldURL) relative to \(String(describing: relativeToDocument)): \(error)")
			}

			return self

		case .bookmark(let b):
			do {
				var stale = false

				#if os(macOS)
					let u = try URL(resolvingBookmarkData: b, options: URL.BookmarkResolutionOptions.withSecurityScope, relativeTo: relativeToDocument, bookmarkDataIsStale: &stale)
				#endif

				#if os(iOS)
					let u = try URL(resolvingBookmarkData: b, options: [], relativeTo: relativeToDocument, bookmarkDataIsStale: &stale)
				#endif

				if stale {
					trace("Just-resolved bookmark is stale: \(String(describing: u))")
					return QBEFileReference.absolute(u)
				}

				return QBEFileReference.resolvedBookmark(b, u, QBEFileAccess(u))
			}
			catch let error as NSError {
				trace("Could not resolve secure bookmark \(b): \(error)")
			}
			return self
		}
	}

	public var bookmark: Data? {
		switch self {
		case .resolvedBookmark(let d, _, _): return d
		case .bookmark(let d): return d
		default: return nil
		}
	}

	public var url: URL? {
		switch self {
		case .absolute(let u): return u
		case .resolvedBookmark(_, let u, _): return u
		default: return nil
		}
	}
}

public func == (lhs: QBEFileReference, rhs: QBEFileReference) -> Bool {
	if let lu = lhs.url, let ru = rhs.url {
		return lu == ru
	}
	else if let lb = lhs.bookmark, let rb = rhs.bookmark {
		return lb == rb
	}
	return false
}

/** QBEFileCoordinator manages file presenters, which are required to obtain access to certain files (e.g. secondary files
such as SQLite's journal files). Call `present` on the shared instance, and retain the returned QBEFilePresenter object 
as long as you need to access the file. */
internal class QBEFileCoordinator {
	static let sharedInstance = QBEFileCoordinator()

	private let mutex = Mutex()
	private var presenters: [URL: Weak<QBEFilePresenter>] = [:]

	func present(_ file: URL, secondaryExtension: String? = nil) -> QBEFilePresenter {
		let presentedFile: URL
		if let se = secondaryExtension {
			presentedFile = (file.deletingPathExtension().appendingPathExtension(se)) 
		}
		else {
			presentedFile = file
		}

		return self.mutex.locked { () -> QBEFilePresenter in
			if let existing = self.presenters[presentedFile]?.value {
				return existing
			}
			else {
				trace("Present new: \(presentedFile)")
				let pres = QBEFilePresenter(primary: file, secondary: presentedFile)
				self.presenters[presentedFile] = Weak(pres)
				return pres
			}
		}
	}
}

internal class QBEPersistedFileReference: NSObject, NSCoding {
	let file: QBEFileReference?

	init(_ file: QBEFileReference?) {
		self.file = file
	}

	required init?(coder aDecoder: NSCoder) {
		let d = aDecoder.decodeObject(forKey: "fileBookmark") as? Data
		let u = aDecoder.decodeObject(forKey: "fileURL") as? URL
		self.file = QBEFileReference.create(u, d)
	}

	func encode(with coder: NSCoder) {
		coder.encode(self.file?.url, forKey: "fileURL")
		coder.encode(self.file?.bookmark, forKey: "fileBookmark")
	}
}

private class QBEFilePresenterDelegate: NSObject, NSFilePresenter {
	#if os(macOS)
		@objc let primaryPresentedItemURL: URL?
	#endif
	@objc let presentedItemURL: URL?

	init(primary: URL, secondary: URL) {
		#if os(macOS)
		self.primaryPresentedItemURL = primary
		#endif
		self.presentedItemURL = secondary
	}

	@objc var presentedItemOperationQueue: OperationQueue {
		return OperationQueue.main
	}
}

/** This needs to be an NSObject subclass, as otherwise it appears it is not destroyed correctly. The QBEFileCoordinator
holds a weak reference to this presenter, but deinit is only called if this file presenter is an NSObject subclass (Swift
bug?). */
public class QBEFilePresenter: NSObject {
	private let delegate: QBEFilePresenterDelegate

	fileprivate init(primary: URL, secondary: URL) {
		self.delegate = QBEFilePresenterDelegate(primary: primary, secondary: secondary)
		NSFileCoordinator.addFilePresenter(delegate)

		/* FIXME this is a bad way to force the file coordinator to sync and actually finish creating the file presenters.
		See: http://thebesthacker.com/question/osx-related-file-creation.html */
		let _ = NSFileCoordinator.filePresenters
	}

	deinit {
		NSFileCoordinator.removeFilePresenter(self.delegate)
	}
}

public class QBEFileRecents {
	private let maxRememberedFiles = 5
	private let preferenceKey: String

	init(key: String) {
		self.preferenceKey = "recents.\(key)"
	}

	public func loadRememberedFiles() -> [QBEFileReference] {
		let files: [String] = (UserDefaults.standard.array(forKey: preferenceKey) as? [String]) ?? []
		return files.flatMap { bookmarkString -> [QBEFileReference] in
			if let bookmarkData = Data(base64Encoded: bookmarkString, options: []) {
				let fileRef = QBEFileReference.bookmark(bookmarkData)
				if let resolved = fileRef.resolve(nil) {
					return [resolved]
				}
			}
			return []
		}
	}

	public func remember(_ file: QBEFileReference) {
		if let bookmarkData = file.persist(nil)?.bookmark {
			var files: [String] = (UserDefaults.standard.array(forKey: preferenceKey) as? [String]) ?? []
			files.insert(bookmarkData.base64EncodedString(options: []), at: 0)
			UserDefaults.standard.setValue(Array(files.prefix(self.maxRememberedFiles)), forKey: preferenceKey)
		}
	}
}
