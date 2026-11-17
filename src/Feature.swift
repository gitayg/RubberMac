// A feature that runs on its own: started once at launch, its event taps started again once Accessibility is on.
protocol Feature: AnyObject {
    // On, and unable to work without Accessibility.
    var wantsAccess: Bool { get }
    func start()
    func restartTaps()
}
