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

internal class QBEColumnsStepView: QBEConfigurableStepViewControllerFor<QBEColumnsStep>, NSTableViewDataSource, NSTableViewDelegate {
	var columns: OrderedSet<Column> = []
	@IBOutlet var tableView: NSTableView?
	
	required init?(configurable: QBEConfigurable, delegate: QBEConfigurableViewDelegate) {
		super.init(configurable: configurable, delegate: delegate, nibName: "QBEColumnsStepView", bundle: nil)
	}
	
	required init?(coder: NSCoder) {
		fatalError("Should not be called")
	}
	
	internal override func viewWillAppear() {
		updateColumns()
		super.viewWillAppear()
		updateView()
	}
	
	private func updateColumns() {
		let job = Job(.userInitiated)
		if let previous = step.previous {
			previous.exampleDataset(job, maxInputRows: 100, maxOutputRows: 100) { (data) -> () in
				data.maybe({$0.columns(job) {(columns) in
					columns.maybe {(cns) in
						asyncMain {
							self.columns = cns
							self.updateView()
						}
					}
				}})
			}
		}
		else {
			columns.removeAll()
			self.updateView()
		}
	}
	
	private func updateView() {
		tableView?.reloadData()
	}
	
	func numberOfRows(in tableView: NSTableView) -> Int {
		return columns.count
	}
	
	func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
		if let identifier = tableColumn?.identifier, identifier.rawValue == "selected" {
			let select = (object as? Bool) ?? false
			let name = columns[row]
			step.columns.remove(name)
			if select {
				step.columns.append(name)
			}
		}
		self.delegate?.configurableView(self, didChangeConfigurationFor: step)
	}
	
	internal func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
		if let tc = tableColumn {
			if convertFromNSUserInterfaceItemIdentifier(tc.identifier) == "column" {
				return columns[row].name
			}
			else {
                return NSNumber(value: step.columns.firstIndex(of: columns[row]) != nil)
			}
		}
		return nil
	}
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromNSUserInterfaceItemIdentifier(_ input: NSUserInterfaceItemIdentifier) -> String {
	return input.rawValue
}
