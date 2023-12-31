/* Warp. Copyright (C) 2014-2017 Pixelspark, Tommy van der Vorst

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, write to the Free
Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. */
import CoreGraphics
import WarpCore

internal extension CGRect {
	func inset(_ inset: CGFloat) -> CGRect {
		return CGRect(
			x: self.origin.x + inset,
			y: self.origin.y + inset,
			width: self.size.width - 2*inset,
			height: self.size.height - 2*inset
		)
	}
	
	var center: CGPoint {
		return CGPoint(x: self.origin.x + self.size.width/2, y: self.origin.y + self.size.height/2)
	}
	
	func centeredAt(_ point: CGPoint) -> CGRect {
		return CGRect(x: point.x - self.size.width/2, y: point.y - self.size.height/2, width: self.size.width, height: self.size.height)
	}
	
	var rounded: CGRect { get {
		return CGRect(x: round(self.origin.x), y: round(self.origin.y), width: round(self.size.width), height: round(self.size.height))
	} }
}

internal extension CGPoint {
	func offsetBy(_ point: CGPoint) -> CGPoint {
		return CGPoint(x: self.x + point.x, y: self.y + point.y)
	}
	
	func distanceTo(_ point: CGPoint) -> CGFloat {
		return hypot(point.x - self.x, point.y - self.y)
	}
}

#if os(macOS)
import Cocoa

internal extension NSAlert {
	static func showSimpleAlert(_ message: String, infoText: String, style: NSAlert.Style, window: NSWindow?) {
		assertMainThread()
		let av = NSAlert()
		av.messageText = message
		av.informativeText = infoText
		av.alertStyle = style

		if let w = window {
			av.beginSheetModal(for: w, completionHandler: nil)
		}
		else {
			av.runModal()
		}
	}
}

@IBDesignable class QBEBorderedView: NSView {
	@IBInspectable var drawBackground: Bool = true
	@IBInspectable var leftBorder: Bool = false
	@IBInspectable var topBorder: Bool = false
	@IBInspectable var rightBorder: Bool = false
	@IBInspectable var bottomBorder: Bool = false
	@IBInspectable var backgroundColor: NSColor = NSColor.windowFrameColor { didSet { self.setNeedsDisplay(self.bounds) } }
	@IBInspectable var borderColor: NSColor = NSColor.windowFrameColor { didSet { self.setNeedsDisplay(self.bounds) } }

	@IBInspectable var gradientStartColor: NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7) { didSet { self.setNeedsDisplay(self.bounds) } }
	@IBInspectable var gradientEndColor: NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6) { didSet { self.setNeedsDisplay(self.bounds) } }
	
	override func draw(_ dirtyRect: NSRect) {
		if drawBackground {
			backgroundColor.set()
			dirtyRect.fill()

			let g = NSGradient(starting: gradientStartColor, ending: gradientEndColor)
			g?.draw(in: self.bounds, angle: 270.0)
		}

		borderColor.set()
		
		if leftBorder {
			CGRect(x: bounds.origin.x, y: bounds.origin.y, width: 1, height: bounds.size.height).fill()
		}
		
		if rightBorder {
			CGRect(x: bounds.origin.x + bounds.size.width, y: bounds.origin.y, width: 1, height: bounds.size.height).fill()
		}
		
		if topBorder {
			CGRect(x: bounds.origin.x, y: bounds.origin.y + bounds.size.height - 1, width: bounds.size.width, height: 1).fill()
		}
		
		if bottomBorder {
			let p = NSBezierPath()
			p.move(to: CGPoint(x: bounds.origin.x, y: bounds.origin.y))
			p.line(to: CGPoint(x: bounds.size.width, y: bounds.origin.y))
			p.stroke()
		}
	}
}

internal extension NSView {
	func orderFront() {
		self.superview?.addSubview(self)
	}

	func removeFromSuperview(_ animated: Bool, completion: (() -> ())? = nil) {
		if !animated {
			self.removeFromSuperview()
			completion?()
			return
		}

		let duration = 0.25
		self.wantsLayer = true

		CATransaction.begin()
		CATransaction.setAnimationDuration(duration)
		CATransaction.setCompletionBlock {
			self.removeFromSuperview()
			completion?()
		}
		let ta = CABasicAnimation(keyPath: "transform")

		// Scale, but centered in the middle of the view
		var end = CATransform3DIdentity
		end = CATransform3DTranslate(end, self.bounds.size.width/2, self.bounds.size.height/2, 0.0)
		end = CATransform3DScale(end, 0.01, 0.01, 0.01)
		end = CATransform3DTranslate(end, -self.bounds.size.width/2, -self.bounds.size.height/2, 0.0)

		var begin = CATransform3DIdentity
		begin = CATransform3DTranslate(begin, self.bounds.size.width/2, self.bounds.size.height/2, 0.0)
		begin = CATransform3DScale(begin, 1.0, 1.0, 0.0)
		begin = CATransform3DTranslate(begin, -self.bounds.size.width/2, -self.bounds.size.height/2, 0.0)

		// Fade in
		ta.fromValue = NSValue(caTransform3D: begin)
		ta.toValue = NSValue(caTransform3D: end)
		ta.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
		self.layer?.add(ta, forKey: "transformAnimation")

		let oa = CABasicAnimation(keyPath: "opacity")
		oa.fromValue = 1.0
		oa.toValue = 0.0
		oa.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
		oa.fillMode = CAMediaTimingFillMode.forwards
		oa.isRemovedOnCompletion = false
		self.layer?.add(oa, forKey: "opacityAnimation")

		CATransaction.commit()
	}
	
	func addSubview(_ view: NSView, animated: Bool, completion: (() -> ())? = nil) {
		if !animated {
			self.addSubview(view)
			completion?()
			return
		}
		
		let duration = 0.35
		view.wantsLayer = true
		self.addSubview(view)
		view.scrollToVisible(view.bounds)
		
		CATransaction.begin()
		CATransaction.setAnimationDuration(duration)
		CATransaction.setCompletionBlock(completion)
		let ta = CABasicAnimation(keyPath: "transform")
		
		// Scale, but centered in the middle of the view
		var begin = CATransform3DIdentity
		begin = CATransform3DTranslate(begin, view.bounds.size.width/2, view.bounds.size.height/2, 0.0)
		begin = CATransform3DScale(begin, 0.0, 0.0, 0.0)
		begin = CATransform3DTranslate(begin, -view.bounds.size.width/2, -view.bounds.size.height/2, 0.0)
		
		var end = CATransform3DIdentity
		end = CATransform3DTranslate(end, view.bounds.size.width/2, view.bounds.size.height/2, 0.0)
		end = CATransform3DScale(end, 1.0, 1.0, 0.0)
		end = CATransform3DTranslate(end, -view.bounds.size.width/2, -view.bounds.size.height/2, 0.0)
		
		// Fade in
		ta.fromValue = NSValue(caTransform3D: begin)
		ta.toValue = NSValue(caTransform3D: end)
		ta.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
		view.layer?.add(ta, forKey: "transformAnimation")
		
		let oa = CABasicAnimation(keyPath: "opacity")
		oa.fromValue = 0.0
		oa.toValue = 1.0
		oa.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
		view.layer?.add(oa, forKey: "opacityAnimation")
		
		CATransaction.commit()
	}
}

#endif
