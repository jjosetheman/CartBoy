import ORSSerial
import Gibby


/**
 Cart reader implementation for insideGadgets.com's 'GBxCart'.
 */
public final class GBxCartReaderController<Cartridge: Gibby.Cartridge>: NSObject, ReaderController {
    private enum ReaderCommand: CustomDebugStringConvertible {
        case start
        case stop
        case `continue`
        case address(_ command: String, radix: Int, address: Int)
        case sleep(_ duration: UInt32)
        
        var debugDescription: String {
            var desc = ""
            switch self {
            case .start:
                desc += "START:\n"
            case .stop:
                desc += "STOP:\n"
            case .continue:
                desc += "CONT:\n"
            case .address(let command, let radix, let address):
                let addr = String(address, radix: radix, uppercase: true)
                desc += "ADDR: \(command);\(radix);\(addr)\n"
            case .sleep(let duration):
                desc += "SLP: \(duration)\n"
            }
            desc += data.hexString()
            return desc
        }
        
        private var data: Data {
            switch self {
            case .start:
                switch Cartridge.Platform.self {
                case is GameboyClassic.Type:
                    return "R".data(using: .ascii)!
                case is GameboyAdvance.Type:
                    return "r".data(using: .ascii)!
                default:
                    fatalError("No 'read' strategy provided for \(Cartridge.Platform.self)")
                }
            case .stop:
                return "0".data(using: .ascii)!
            case .continue:
                return "1".data(using: .ascii)!
            case .address(let command, let radix, let address):
                let addr = String(address, radix: radix, uppercase: true)
                return "\(command)\(addr)\0".data(using: .ascii)!
            default:
                return Data()
            }
        }

        func send(to reader: ORSSerialPort) {
            guard case .sleep(let duration) = self else {
                reader.send(self.data)
                return
            }
            usleep(duration)
        }
    }
    
    /**
     */
    public init(matching portProfile: ORSSerialPortManager.PortProfile = .GBxCart) throws {
        self.reader = try ORSSerialPortManager.port(matching: portProfile)
    }

    ///
    private let reader: ORSSerialPort
    
    ///
    private let queue = OperationQueue()
    
    ///
    public var isOpen: Bool {
        return self.reader.isOpen
    }
    
    /**
     */
    private func send(_ command: ReaderCommand...) {
        command.forEach {
            $0.send(to: self.reader)
        }
    }

    ///
    public var delegate: ORSSerialPortDelegate? {
        get {
            return reader.delegate
        }
        set {
            reader.delegate = newValue
        }
    }

    /**
     */
    @discardableResult
    public func closePort() -> Bool {
        return self.reader.close()
    }

    /**
     */
    public func addOperation(_ operation: Operation) {
        self.queue.addOperation(operation)
    }

    /**
     */
    public func readOperationWillBegin(_ operation: Operation) {
        guard let readOp = operation as? ReadPortOperation<GBxCartReaderController> else {
            operation.cancel()
            return
        }
        
        switch readOp.context {
        case .header:
            let address = Int(Cartridge.Platform.headerRange.lowerBound)
            self.send(.address("\0A", radix: 16, address: address))
        case .bank(let bank, let header):
            self.send(.stop)
            self.set(bank: bank, with: header)
            self.send(.address("\0A", radix: 16, address: bank > 1 ? 0x4000 : 0x0000))
        default: ()
        }
    }
    
    /**
     */
    public func readOperationDidBegin(_ operation: Operation) {
        guard let readOp = operation as? ReadPortOperation<GBxCartReaderController> else {
            operation.cancel()
            return
        }

        switch readOp.context {
        case .header:
            self.send(.start)
        case .bank:
            self.send(.start)
        default: ()
        }
    }

    /**
     */
    public func readOperation(_ operation: Operation, didRead progress: Progress) {
        guard let readOp = operation as? ReadPortOperation<GBxCartReaderController> else {
            operation.cancel()
            return
        }
        
        let pageSize = 64
        _ = readOp.context

        switch readOp.context {
        case .cartridge:
            // print(progress.fractionCompleted)
            ()
        default:
            if (Int(progress.completedUnitCount) % pageSize) == 0 {
                self.send(.continue)
            }
        }
    }
    
    /**
     */
    public func readOperationDidComplete(_ operation: Operation) {
        self.delegate = nil
        
        guard let readOp = operation as? ReadPortOperation<GBxCartReaderController> else {
            operation.cancel()
            return
        }
        
        switch readOp.context {
        case .header:
            /// - warning: Another important 'pause'; don't delete.
            self.send(.stop, .sleep(75))
        default: ()
        }
    }
    
    /**
     */
    public final func openReader(delegate: ORSSerialPortDelegate?) throws {
        self.delegate = delegate
        
        if self.reader.isOpen == false {
            self.reader.open()
            self.reader.configuredAsGBxCart()
        }

        guard self.reader.isOpen else {
            throw ReaderControllerError.failedToOpen(self.reader)
        }
    }
    
    private func set<Header>(bank: Int, with header: Header) where Header == Cartridge.Header {
        switch Cartridge.Platform.self {
        case is GameboyClassic.Type:
            /// The amount of microseconds between setting the bank address, and
            /// settings the bank number.
            ///
            /// - warning: Modifying or removing `timeout` will cause bank switching
            /// to fail! There is a tolerance of how low it can be set; for best
            /// results, stay between _150_ & _250_.
            let timeout: UInt32 = 150
            //------------------------------------------------------------------
            
            let header = header as! GameboyClassic.Cartridge.Header
            if case .one = header.configuration {
                self.send(
                    .address("B", radix: 16, address: 0x6000)
                  , .sleep(timeout)
                  , .address("B", radix: 10, address: 0)
                )

                self.send(
                    .address("B", radix: 16, address: 0x4000)
                  , .sleep(timeout)
                  , .address("B", radix: 10, address: bank >> 5)
                )

                self.send(
                    .address("B", radix: 16, address: 0x2000)
                  , .sleep(timeout)
                  , .address("B", radix: 10, address: bank & 0x1F)
                )
            }
            else {
                self.send(
                    .address("B", radix: 16, address: 0x2100)
                  , .sleep(timeout)
                  , .address("B", radix: 10, address: bank)
                )
                if bank >= 0x100 {
                    self.send(
                        .address("B", radix: 16, address: 0x3000)
                      , .sleep(timeout)
                      , .address("B", radix: 10, address: 1)
                    )
                }
            }
        case is GameboyAdvance.Type:
            fatalError()
        default:
            fatalError("No 'read' strategy provided for \(Cartridge.Platform.self)")
        }
    }
}
