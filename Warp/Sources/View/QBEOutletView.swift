/* Warp. Copyright (C) 2014-2017 Pixelspark, Tommy van der Vorst

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, write to the Free
Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. */
import Cocoa
import UniformTypeIdentifiers

@objc protocol QBEOutletDropTarget: NSObjectProtocol {
	func receiveDropFromOutlet(_ draggedObject: AnyObject?)
}

private extension NSPasteboard {
	var pasteURL: URL? { get {
		var pasteboardRef: Pasteboard? = nil
		PasteboardCreate(self.name.rawValue as CFString, &pasteboardRef)
		if let realRef = pasteboardRef {
			PasteboardSynchronize(realRef)
			var pasteURL: CFURL? = nil
			PasteboardCopyPasteLocation(realRef, &pasteURL)

			if let realURL = pasteURL {
				let url = realURL as URL
				return url
			}
		}

		return nil
	} }
}

/**
QBEOutletDropView provides a 'drop zone' for outlets. Set a delegate to accept objects received from dropped outlet 
connections.
*/
class QBEOutletDropView: NSView {
	private var isDraggingOver: Bool = false
	weak var delegate: QBEOutletDropTarget? = nil
	
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		registerForDraggedTypes([QBEOutletView.dragType])
		self.wantsLayer = true
		self.layer!.cornerRadius = QBEResizableView.cornerRadius
		self.layer!.masksToBounds = true
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
	
	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
		isDraggingOver = true
		setNeedsDisplay(self.bounds)
		return delegate != nil ? NSDragOperation.private : NSDragOperation()
	}
	
	override func draggingExited(_ sender: NSDraggingInfo?) {
		isDraggingOver = false
		setNeedsDisplay(self.bounds)
	}
	
	override func draggingEnded(_ sender: NSDraggingInfo) {
		isDraggingOver = false
		setNeedsDisplay(self.bounds)
	}
	
	override func performDragOperation(_ draggingInfo: NSDraggingInfo) -> Bool {
		let pboard = draggingInfo.draggingPasteboard
		
		if let _ = pboard.data(forType: QBEOutletView.dragType) {
			if let ov = draggingInfo.draggingSource as? QBEOutletView {
				delegate?.receiveDropFromOutlet(ov.draggedObject)
				return true
			}
		}
		return false
	}
	
	override func hitTest(_ aPoint: NSPoint) -> NSView? {
		return nil
	}
	
	override func draw(_ dirtyRect: NSRect) {
		if isDraggingOver {
			NSColor.blue.withAlphaComponent(0.15).set()
		}
		else {
			NSColor.clear.set()
		}
		
		dirtyRect.fill()
	}
	
	override var acceptsFirstResponder: Bool { get { return false } }
}

/** 
QBELaceView draws the actual 'lace' between source and dragging target when dragging an outlet. It is put inside the
QBELaceWindow, which overlays both source and target point. 
*/
private class QBELaceView: NSView {
	weak var source: QBEOutletView? { didSet { setNeedsDisplay(self.bounds) } }
	var targetScreenPoint: CGPoint = CGPoint(x: 0, y: 0) { didSet { setNeedsDisplay(self.bounds) } }
	
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
	}

	required init?(coder: NSCoder) {
	    fatalError("init(coder:) has not been implemented")
	}
	
	private var sourceScreenRect: CGRect? { get {
		if let s = source {
			let frameInWindow = s.convert(s.bounds, to: nil)
			return s.window?.convertToScreen(frameInWindow)
		}
		return nil
	} }
	
	fileprivate override func hitTest(_ aPoint: NSPoint) -> NSView? {
		return nil
	}
	
	fileprivate override func draw(_ dirtyRect: NSRect) {
		if let context = NSGraphicsContext.current?.cgContext {
			context.saveGState()
			
			if let sourceRect = sourceScreenRect, let w = self.window {
				// Translate screen point to point in this view
				let sourcePointWindow = w.convertFromScreen(sourceRect).center
				let sourcePointView = self.convert(sourcePointWindow, from: nil)
				let targetPointWindow = w.convertFromScreen(CGRect(x: targetScreenPoint.x, y: targetScreenPoint.y, width: 1, height: 1)).origin
				let targetPointView = self.convert(targetPointWindow, from: nil)
				
				// Draw a line
				context.move(to: CGPoint(x: sourcePointView.x, y: sourcePointView.y))
				context.addLine(to: CGPoint(x: targetPointView.x, y: targetPointView.y))
				NSColor.blue.setStroke()
				context.setLineWidth(3.0)
				context.strokePath()
			}
			
			context.restoreGState()
		}
	}
}

/** 
QBELaceWindow is an overlay window created before an outlet is being dragged, and is resized to cover both the source
outlet view as well as the (current) target dragging point. The overlay window is used to draw a 'lace' between source 
and dragging target (much like in Interface Builder)
*/
private class QBELaceWindow: NSWindow {
	weak var source: QBEOutletView? { didSet { updateGeometry() } }
	var targetScreenPoint: CGPoint = CGPoint(x: 0, y: 0) { didSet { updateGeometry() } }
	private var laceView: QBELaceView
	
	init() {
		laceView = QBELaceView(frame: NSZeroRect)
		super.init(contentRect: NSZeroRect, styleMask: NSWindow.StyleMask.borderless, backing: NSWindow.BackingStoreType.buffered, defer: false)
		backgroundColor = NSColor.clear
		isReleasedWhenClosed = false
		isOpaque = false
		isMovableByWindowBackground = false
		isExcludedFromWindowsMenu = true
		self.hasShadow = true
		self.acceptsMouseMovedEvents = false
		laceView.frame = self.contentLayoutRect
		contentView = laceView
		unregisterDraggedTypes()
		ignoresMouseEvents = true
	}
	
	var sourceScreenFrame: CGRect? { get {
		if let s = source {
			let frameInWindow = s.convert(s.bounds, to: nil)
			return s.window?.convertToScreen(frameInWindow)
		}
		return nil
	} }
	
	private func updateGeometry() {
		if let s = source, let frameInScreen = sourceScreenFrame, targetScreenPoint.x.isFinite && targetScreenPoint.y.isFinite {
			let rect = CGRect(
				x: min(frameInScreen.center.x, targetScreenPoint.x),
				y: min(frameInScreen.center.y, targetScreenPoint.y),
				width: max(frameInScreen.center.x, targetScreenPoint.x) - min(frameInScreen.center.x, targetScreenPoint.x),
				height: max(frameInScreen.center.y, targetScreenPoint.y) - min(frameInScreen.center.y, targetScreenPoint.y)
			)
			self.setFrame(rect.insetBy(dx: -s.bounds.size.width, dy: -s.bounds.size.height), display: true, animate: false)
		}
		
		laceView.source = source
		laceView.targetScreenPoint = targetScreenPoint
		laceView.setNeedsDisplay(laceView.bounds)
	}
}

@objc protocol QBEOutletViewDelegate: NSObjectProtocol {
	func outletViewWillStartDragging(_ view: QBEOutletView)
	func outletViewDidEndDragging(_ view: QBEOutletView)
	@objc optional func outletViewWasClicked(_ view: QBEOutletView)
	func outletView(_ view: QBEOutletView, didDropAtURL: URL, callback: @escaping (Error?) -> ())
}

/** 
QBEOutletView shows an 'outlet' from which an item can be dragged. Views that want to accept outlet drops need to accept
the QBEOutletView.dragType dragging type. Upon receiving a dragged outlet, they should find the dragging source (which 
will be the sending QBEOutletView) and then obtain the draggedObject from that view. */
@IBDesignable class QBEOutletView: NSView, NSDraggingSource, NSPasteboardItemDataProvider, NSFilePromiseProviderDelegate {
	static let dragType = NSPasteboard.PasteboardType("nl.pixelspark.Warp.Outlet")

	@IBInspectable var animating: Bool {
		get {
			return self.timer != nil && self.endTimerAfter == nil
		}

		set(animate) {
			let wasAnimating = self.timer != nil && self.endTimerAfter == nil
			if animate == wasAnimating {
				return
			}

			if animate {
				self.endTimerAfter = nil
				if self.timer == nil {
					self.timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(updateFromTimer(_:)), userInfo: nil, repeats: true)
					RunLoop.current.add(self.timer, forMode: RunLoop.Mode.default)
				}
			}
			else {
				self.endTimerAfter = NSDate.timeIntervalSinceReferenceDate + 1.0
			}
		}
	}

	@IBInspectable var progress: Double = 1.0 { didSet {
		assert(progress >= 0.0 && progress <= 1.0, "progress must be [0,1]")
		setNeedsDisplay(self.bounds)
	} }

	private var endTimerAfter: TimeInterval? = nil
	
	@IBInspectable var enabled: Bool = true { didSet { setNeedsDisplay(self.bounds) } }
	@IBInspectable var connected: Bool = false { didSet { setNeedsDisplay(self.bounds) } }
	weak var delegate: QBEOutletViewDelegate? = nil
	var draggedObject: AnyObject? = nil
	
	private var dragLineWindow: QBELaceWindow?
	private var timer: Timer!

	@objc private func updateFromTimer(_ timer: Timer) {
		if let et = self.endTimerAfter, NSDate.timeIntervalSinceReferenceDate > et {
			self.timer?.invalidate()
			self.timer = nil
		}
		setNeedsDisplay(self.bounds)
	}

	override func mouseDown(with theEvent: NSEvent) {
		if enabled {
			delegate?.outletViewWillStartDragging(self)
			
			if draggedObject != nil {
				if #available(OSX 10.12, *) {
					/* On OSX >10.12, we use the official API for file promises. Because we also want to drag our own item
					at the same time (for outlet connection inside the app) we subclass NSFilePromiseProvider here. Note
					that for some reason, proxying NSFilePromiseProvider doesn't work. */
					class QBEOutletFilePromiseProvider: NSFilePromiseProvider {
						convenience init(fileType: UTType, delegate: NSFilePromiseProviderDelegate) {
							self.init()
                            self.fileType = fileType.identifier
							self.delegate = delegate
						}

						fileprivate override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
							var types = super.writableTypes(for: pasteboard)
							types.append(QBEOutletView.dragType)
							return types
						}

						fileprivate override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
							if type == QBEOutletView.dragType {
								return []
							}
							return super.writingOptions(forType: type, pasteboard: pasteboard)
						}

						fileprivate override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
							if type == QBEOutletView.dragType {
								return nil
							}
							return super.pasteboardPropertyList(forType: type)
						}
					}

                    let promisedFile = QBEOutletFilePromiseProvider(fileType: UTType.commaSeparatedText, delegate: self)
					let fileDragItem = NSDraggingItem(pasteboardWriter: promisedFile)
					fileDragItem.draggingFrame = NSMakeRect(fileDragItem.draggingFrame.origin.x, fileDragItem.draggingFrame.origin.y, 10, 10)

					self.beginDraggingSession(with: [fileDragItem] as [NSDraggingItem], event: theEvent, source: self)
				}
				else {
					/* Use the 'unofficial' API for file promises on OS X < 10.12 */
					let pboardItem = NSPasteboardItem()
					pboardItem.setData("[dragged outlet]".data(using: String.Encoding.utf8, allowLossyConversion: false)!, forType: QBEOutletView.dragType)

					/* When this item is dragged to a finder window, promise to write a CSV file there. Our provideDatasetForType
					function is called as soon as the system actually wants us to write that file. */
					pboardItem.setDataProvider(self, forTypes: [NSPasteboard.PasteboardType(rawValue: kPasteboardTypeFileURLPromise)])
					pboardItem.setString(kUTTypeCommaSeparatedText as String, forType: NSPasteboard.PasteboardType.filePromise)

					let dragItem = NSDraggingItem(pasteboardWriter: pboardItem)
					self.beginDraggingSession(with: [dragItem] as [NSDraggingItem], event: theEvent, source: self)
				}
			}
		}
	}

	@available(OSX 10.12, *)
	func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
		return "Data.csv".localized
	}

	@available(OSX 10.12, *)
	func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
		self.delegate?.outletView(self, didDropAtURL: url, callback: completionHandler)
	}

	func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
		if type.rawValue == kPasteboardTypeFileURLPromise {
			// pasteURL is the directory to write something to. Now is a good time to pop up an export dialog
			if let pu = pasteboard?.pasteURL {
				self.delegate?.outletView(self, didDropAtURL: pu) { err in
					if let e = err {
						Swift.print("Export failed: \(e)")
					}
				}
				item.setString(pu.absoluteString, forType: NSPasteboard.PasteboardType.filePromise)
			}
		}
	}
	
	override func draw(_ dirtyRect: NSRect) {
		if let context = NSGraphicsContext.current?.cgContext {
			context.saveGState()
			
			// Largest square that fits in this view
			let minDimension = min(self.bounds.size.width, self.bounds.size.height)
			let square = CGRect(x: (self.bounds.size.width - minDimension) / 2, y: (self.bounds.size.height - minDimension) / 2, width: minDimension, height: minDimension).insetBy(dx: 3.0, dy: 3.0)
			
			if !square.origin.x.isInfinite && !square.origin.y.isInfinite {
				// Draw the outer ring (always visible, dimmed if no dragging item set)
				let isProgressing = self.progress < 1.0
				let isDragging = (draggedObject != nil)

				let opacity: Double
				if let et = self.endTimerAfter {
					opacity = max(0.0, et - NSDate.timeIntervalSinceReferenceDate)
				}
				else {
					opacity = 1.0
				}

				let baseColor: NSColor
				if enabled {
					if isDragging {
						baseColor = NSColor(calibratedRed: 100.0/255.0, green: 97.0/255.0, blue: 97.0/255.0, alpha: CGFloat(1.0 * (1.0 - opacity)))
					}
					else {
						baseColor = NSColor(calibratedRed: 100.0/255.0, green: 97.0/255.0, blue: 97.0/255.0, alpha: CGFloat(0.5 * (1.0 - opacity)))
					}
				}
				else {
					if isProgressing {
						baseColor = NSColor(calibratedRed: 100.0/255.0, green: 97.0/255.0, blue: 97.0/255.0, alpha: CGFloat(0.2 * (1.0 - opacity)))
					}
					else {
						baseColor = NSColor(calibratedRed: 100.0/255.0, green: 97.0/255.0, blue: 97.0/255.0, alpha: CGFloat(0.2 * (1.0 - opacity)))
					}
				}

				context.setLineWidth(3.0)
				let offset: CGFloat = 3.14159 / 2.0
				let t = CGAffineTransform(translationX: square.center.x, y: square.center.y)

				if self.timer != nil {
					let progressRing = CGMutablePath()
					let time = fmod(NSDate.timeIntervalSinceReferenceDate, 1.0)
					let timeForAnimation = 0.5 * time + 0.5 * (time * time)
					let progressForAnimation = 0.05 + 0.95 * progress

					let progressAngle = CGFloat(2.0 * 3.141459 * (1.0 - timeForAnimation)) + offset
					let progressEndAngle = progressAngle + CGFloat(2.0 * 3.141459 * progressForAnimation)
					progressRing.addArc(center: CGPoint(x: 0, y:0), radius: square.size.width / 2, startAngle: progressAngle, endAngle: progressEndAngle, clockwise: false, transform: t)
					context.addPath(progressRing)
					NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.5, alpha: 0.5 * CGFloat(opacity)).setStroke()
					context.strokePath()
				}

				if self.timer == nil || self.endTimerAfter != nil {
					baseColor.setStroke()
					let ring = CGMutablePath()
					let progress = 1.0
					ring.addArc(center: CGPoint(x: 0, y: 0), radius: square.size.width / 2, startAngle: offset + CGFloat(2.0 * 3.141459 * (1.0 - progress)), endAngle: offset + CGFloat(2.0 * 3.14159), clockwise: false, transform: t)
					context.addPath(ring)
					context.strokePath()
				}
				
				// Draw the inner circle (if the outlet is connected)
				if connected || dragLineWindow !== nil {
					if dragLineWindow !== nil {
						NSColor.blue.setFill()
					}
					else {
						baseColor.setFill()
					}
					let connectedSquare = square.insetBy(dx: 3.0, dy: 3.0)
					context.fillEllipse(in: connectedSquare)
				}
			}
			
			context.restoreGState()
		}
	}

	override func resetCursorRects() {
		addCursorRect(self.bounds, cursor: NSCursor.openHand)
	}
	
	override func updateTrackingAreas() {
		self.window?.invalidateCursorRects(for: self)
		super.updateTrackingAreas()
	}
	
	func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
		return NSDragOperation.copy
	}
	
	func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
		dragLineWindow = QBELaceWindow()
		dragLineWindow!.source = self
		dragLineWindow?.targetScreenPoint = screenPoint
		dragLineWindow!.orderFront(nil)
		setNeedsDisplay(self.bounds)
		NSCursor.closedHand.push()
	}
	
	func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
		dragLineWindow?.targetScreenPoint = screenPoint
		dragLineWindow?.update()
	}
	
	func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
		defer {
			dragLineWindow?.close()
			dragLineWindow = nil
			setNeedsDisplay(self.bounds)
			NSCursor.pop()
		}

		let screenRect = CGRect(x: screenPoint.x, y: screenPoint.y, width: 0, height: 0)
		if let windowRect = self.window?.convertFromScreen(screenRect) {
			let viewRect = self.convert(windowRect, from: nil)
			if self.bounds.contains(viewRect.origin) {
				self.delegate?.outletViewWasClicked?(self)
				return
			}
		}

		self.delegate?.outletViewDidEndDragging(self)
	}
}
