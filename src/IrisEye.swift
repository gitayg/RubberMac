import CoreGraphics

// One eye in a camera frame, as EyeTracker finds it and IrisRecolor paints it. All in the frame's pixels, with the
// origin at the top left and y going down.
struct IrisEye: Equatable {
    var center: CGPoint
    // The iris's radius.
    var radius: CGFloat
    // The eye opening, a closed polygon: the recolouring stays inside it, off the eyelids.
    var contour: [CGPoint]
    // The opening's height over its width: about 0.05 closed, 0.3 and more wide open.
    var openness: CGFloat
    // How strongly to recolour this eye, 0...1: it fades out as the eye closes or drops out of tracking.
    var alpha: CGFloat = 1
}
