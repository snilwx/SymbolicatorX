//
//  DeviceCrashViewController.swift
//  SymbolicatorX
//
//  Created by 钟晓跃 on 2020/7/17.
//  Copyright © 2020 钟晓跃. All rights reserved.
//

import Cocoa

typealias CrashFileHandler = (CrashFile) -> Void

class DeviceCrashViewController: BaseViewController {
    
    private let devicePopBtn = NSPopUpButton()
    private let appPopBtn = NSPopUpButton()
    private let tableView = CrashFileTableView()
    private let emptyLab = NSTextField()
    private var confirmBtn: NSButton!
    private let textWindowController = SymbolicatedWindowController()
    
    private var afcClient: AfcClient?
    public var crashFileHandle: CrashFileHandler?
    private var disposable: Disposable?
    private var deviceList = [Device]()
    
    private var appInfoDict = [String:Plist]() {
        didSet {
            self.appPopBtn.removeAllItems()
            self.appPopBtn.addItems(withTitles: ["All File"] + self.appInfoDict.keys.sorted())
            self.selectLastApp()
            self.loadCrashFileData()
        }
    }
    
    private var crashFileList = [FileModel]() {
        didSet {
            crashFileList.sort { (file1, file2) -> Bool in
                return file1.date!.compare(file2.date!) == .orderedDescending
            }
            
            DispatchQueue.main.async {
                self.tableView.reloadData()
                self.emptyLab.isHidden = self.crashFileList.count > 0
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        setupUI()
        deviceEventSubscribe()
    }
    
    deinit {
        deviceList.forEach { ( device) in
            var device = device
            device.free()
        }
        _ = MobileDevice.eventUnsubscribe()
        disposable?.dispose()
        afcClient?.free()
        afcClient?.free()
    }
}

// MARK: - Load Data
extension DeviceCrashViewController {
    
    private func deviceEventSubscribe() {
        
        do {
            disposable = try MobileDevice.eventSubscribe { [weak self] (event) in
                
                guard
                    let `self` = self,
                    let udid = event.udid,
                    let type = event.type,
                    let connectionType = event.connectionType,
                    connectionType == .usbmuxd
                else {
                    return
                }
                
                let isExist = self.deviceList.count > 0 && self.deviceList.contains { (device) -> Bool in
                    let deviceUDID = try? device.getUDID()
                    return deviceUDID == udid
                }

                switch type {
                    
                case .add:
                    if !isExist {
                        self.addDevice(udid: udid, connectionType: connectionType)
                    }
                case .remove:
                    if isExist {
                        self.removeDevice(udid: udid)
                    }
                case .paired:
                    print("paired udid: \(udid)")
                    break
                }
            }
        } catch {
            view.window?.alert(message: error.localizedDescription)
        }
    }
    
    private func addDevice(udid: String, connectionType: ConnectionType) {
        
        var option: DeviceLookupOptions = .usbmux
        if connectionType == .network {
            option = .network
        }
        
        DispatchQueue.main.async {
            
            do {
                var device = try Device(udid: udid, options: option)
                var lockdownClient = try LockdownClient(device: device, withHandshake: false)
                let deviceName = try lockdownClient.getName()
                device.name = deviceName
                self.deviceList.append(device)
                self.devicePopBtn.addItem(withTitle: deviceName)
                if self.deviceList.count == 1 {
                    self.loadAppData()
                }
                lockdownClient.free()
            } catch {
                self.view.window?.alert(message: error.localizedDescription)
            }
            
        }
    }
    
    private func removeDevice(udid: String) {
        
        DispatchQueue.main.async {
            
            var isNeedRefresh = false
            self.deviceList.removeAll { (device) -> Bool in
                
                var device = device
                let deviceUDID = try? device.getUDID()
                if deviceUDID == udid {
                    
                    let deviceName = device.name ?? ""
                    if self.devicePopBtn.selectedItem?.title == deviceName {
                        isNeedRefresh = true
                    }
                    
                    self.devicePopBtn.removeItem(withTitle: deviceName)
                    device.free()
                    return true
                }
                return false
            }
            
            if isNeedRefresh {
                self.loadAppData()
            }
            
            if self.deviceList.count == 0 {
                self.clearData()
            }
        }
    }
    
    private func loadAppData() {
        
        guard
            deviceList.count > 0,
            devicePopBtn.indexOfSelectedItem < deviceList.count
            else { return }
        let device = deviceList[devicePopBtn.indexOfSelectedItem]
        
        let options = Plist(dictionary: ["ApplicationType":Plist(string: "User")])
        do {
            var lockdownClient = try LockdownClient(device: device, withHandshake: true)
            var installService = try lockdownClient.getService(service: .installationProxy)
            var install = try InstallationProxy(device: device, service: installService)
            let appListPlist = try install.browse(options: options)
            
            var appInfoDict = [String:Plist]()
            _ = appListPlist.array?.map({ (appInfoItem) -> Plist in
                
                if let appName = appInfoItem["CFBundleDisplayName"]?.string {
                    appInfoDict[appName] = appInfoItem
                }
                return appInfoItem
            })
            self.appInfoDict = appInfoDict
            
            lockdownClient.free()
            installService.free()
            install.free()
        } catch {
            view.window?.alert(message: error.localizedDescription)
        }
    }
    
    private func loadCrashFileData() {
        
        guard
            deviceList.count > 0,
            devicePopBtn.indexOfSelectedItem < deviceList.count,
            appPopBtn.indexOfSelectedItem < appInfoDict.count
        else { return }
        
        let device = deviceList[devicePopBtn.indexOfSelectedItem]
        let title = appPopBtn.selectedItem?.title ?? ""
        let appInfo = appInfoDict[title]
        let process = appInfo?["CFBundleExecutable"]?.string ?? ""
        
        lastSelectedAppID = appInfo?["CFBundleIdentifier"]?.string
        
        DispatchQueue.global().async {
            do {
                var lockdownClient = try LockdownClient(device: device, withHandshake: true)
                var lockdownService = try lockdownClient.getService(service: .crashreportcopymobile)
                let afcClient = try AfcClient(device: device, service: lockdownService)
                let crashFileList = try afcClient.readDirectory(path: ".")
                let retiredFileList = try afcClient.readDirectory(path: "./Retired")
                
                let crashList = crashFileList.compactMap { (fileName) -> FileModel? in

                    guard
                        fileName != "." && fileName != "..",
                        title == "All File" || fileName.scan(pattern: "^(\(process))-\\d{4}-\\d{2}-\\d{2}-\\d{6}").count > 0,
                        let fileInfo = try? afcClient.getFileInfo(path: fileName)
                    else { return nil }
                    
                    let file = FileModel(filePath: fileName, fileInfo: fileInfo, afcClient: afcClient)
                    return file.isDirectory ? nil : file
                }
                
                let retiredList = retiredFileList.compactMap { (fileName) -> FileModel? in
                    
                    guard
                        fileName != "." && fileName != "..",
                        title == "All File" || fileName.scan(pattern: "^(\(process))-\\d{4}-\\d{2}-\\d{2}-\\d{6}").count > 0,
                        let fileInfo = try? afcClient.getFileInfo(path: "./Retired/\(fileName)")
                    else { return nil }
                    
                    let file = FileModel(filePath: "./Retired/\(fileName)", fileInfo: fileInfo, afcClient: afcClient)
                    return file.isDirectory ? nil : file
                }
                
                self.crashFileList = crashList + retiredList
                lockdownClient.free()
                lockdownService.free()
                self.afcClient = afcClient
            } catch {
                self.view.window?.alert(message: error.localizedDescription)
            }
        }
    }
    
    private func clearData() {
        crashFileList.removeAll()
        devicePopBtn.removeAllItems()
        appPopBtn.removeAllItems()
        tableView.reloadData()
    }
}

// MARK: - Action
extension DeviceCrashViewController {
    
    @objc private func didClickConfirmBtn() {
        
        guard
            tableView.selectedRow < crashFileList.count,
            let crashFile = CrashFile(file: crashFileList[tableView.selectedRow])
        else { return }
        
        crashFileHandle?(crashFile)
        didClickBackBtn()
    }
    
    @objc private func didClickBackBtn() {
        
        guard
            let window = view.window,
            let parent = window.parent
        else { return }

        parent.endSheet(window)
    }
    
    @objc private func didChangeDevice(_ sender: NSPopUpButton) {
        
        loadAppData()
    }
    
    @objc private func didChangeApp(_ sender: NSPopUpButton) {
        
        loadCrashFileData()
    }
}

// MARK: - CrashFileTableViewDelegate
extension DeviceCrashViewController: CrashFileTableViewDelegate {
    
    func didClickMenu(type: MenuType, selectedRow: Int) {
        
        let fileInfo = crashFileList[selectedRow]
        guard let data = fileInfo.data, let content = String(data: data, encoding: .utf8) else { return }
        
        switch type {
        case .view:
            textWindowController.showWindow(nil)
            textWindowController.fileName = fileInfo.name
            textWindowController.text = content
            break
        case .save:
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = fileInfo.name
            savePanel.beginSheetModal(for: view.window!) { (response) in
                
                switch response {
                case .OK:
                    guard let url = savePanel.url else { return }
                    try? content.write(to: url, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                default:
                    return
                }
            }
            break
        }
    }
    
}

// MARK: - NSTableViewDataSource
extension DeviceCrashViewController: NSTableViewDataSource {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        
        return crashFileList.count
    }
    
}

// MARK: - NSTableViewDelegate
extension DeviceCrashViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        var cell: NSTableCellView?
        if tableColumn == tableView.tableColumns[0] {
            cell = NSTableCellView.makeCellView(tableView: tableView, identifier: .process)
            cell?.textField?.stringValue = crashFileList[row].name
        } else {
            cell = NSTableCellView.makeCellView(tableView: tableView, identifier: .date)
            cell?.textField?.stringValue = crashFileList[row].dateStr
        }
        
        return cell
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        confirmBtn.isEnabled = tableView.selectedRowIndexes.count > 0
    }
    
}

// MARK: - Cell Identifier
extension NSUserInterfaceItemIdentifier {
    static let process = NSUserInterfaceItemIdentifier("Process")
    static let date = NSUserInterfaceItemIdentifier("Date")
    static let file = NSUserInterfaceItemIdentifier("File")
    static let name = NSUserInterfaceItemIdentifier(rawValue: "Name")
}

// MARK: - Restory Last Selected
extension DeviceCrashViewController {
    
    var lastSelectedAppID: String? {
        get {
            UserDefaults.standard.string(forKey: "lastSelectedAppID")
        }
        set{
            UserDefaults.standard.setValue(newValue, forKey: "lastSelectedAppID")
        }
    }

    private func selectLastApp() {
        
        guard let lastAppID = lastSelectedAppID else { return }
        
        let appInfo = appInfoDict.values.first { (appInfo) -> Bool in
            guard let appID = appInfo["CFBundleIdentifier"]?.string else { return false }
            
            return appID == lastAppID
        }
        
        if let appName = appInfo?["CFBundleDisplayName"]?.string {
            appPopBtn.selectItem(withTitle: appName)
        }
    }
}

// MARK: - UI
extension DeviceCrashViewController {
    
    private func setupUI() {

        confirmBtn = NSButton.makeButton(title: "Confirm", target: self, action: #selector(didClickConfirmBtn))
        confirmBtn.isEnabled = false
        view.addSubview(confirmBtn)
        confirmBtn.snp.makeConstraints { (make) in
            make.right.equalToSuperview().offset(-10)
            make.top.equalToSuperview().offset(10)
        }
        
        let backBtn = NSButton.makeButton(title: "Back", target: self, action: #selector(didClickBackBtn))
        view.addSubview(backBtn)
        backBtn.snp.makeConstraints { (make) in
            make.right.equalTo(confirmBtn.snp.left).offset(-10)
            make.top.equalTo(confirmBtn)
        }
        
        devicePopBtn.target = self
        devicePopBtn.action = #selector(didChangeDevice(_:))
        devicePopBtn.focusRingType = .none
        view.addSubview(devicePopBtn)
        devicePopBtn.snp.makeConstraints { (make) in
            make.top.left.equalToSuperview().offset(10)
            make.width.equalTo(120)
        }
        
        appPopBtn.target = self
        appPopBtn.action = #selector(didChangeApp(_:))
        appPopBtn.focusRingType = .none
        view.addSubview(appPopBtn)
        appPopBtn.snp.makeConstraints { (make) in
            make.top.equalTo(devicePopBtn)
            make.left.equalTo(devicePopBtn.snp.right).offset(10)
            make.width.equalTo(285)
        }
        
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.focusRingType = .none
        tableView.rowHeight = 20
        tableView.delegate = self
        tableView.dataSource = self
        tableView.menuDelegate = self
        
        let column1 = NSTableColumn(identifier: .name)
        column1.title = "name"
        column1.width = 420
        column1.maxWidth = 450
        column1.minWidth = 160
        tableView.addTableColumn(column1)
        
        let column2 = NSTableColumn(identifier: .date)
        column2.title = "date"
        column2.width = 160
        tableView.addTableColumn(column2)
        
        let scrollView = NSScrollView()
        scrollView.focusRingType = .none
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        view.addSubview(scrollView)
        scrollView.snp.makeConstraints { (make) in
            make.bottom.right.equalToSuperview().offset(-10)
            make.left.equalToSuperview().offset(10)
            make.top.equalTo(devicePopBtn.snp.bottom).offset(10)
        }
        
        emptyLab.stringValue = "Data Empty"
        emptyLab.isEditable = false
        emptyLab.isBezeled = false
        emptyLab.bezelStyle = .roundedBezel
        view.addSubview(emptyLab)
        emptyLab.snp.makeConstraints { (make) in
            make.center.equalTo(scrollView)
        }
        
    }
    
}
