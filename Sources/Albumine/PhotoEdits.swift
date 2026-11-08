import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Retouches non destructives : enregistrées dans Albumine, appliquées à l'affichage et à l'export.
/// Le fichier d'origine n'est jamais modifié.
struct PhotoEdits: Codable, Equatable, Hashable {
    enum Filter: String, Codable, CaseIterable, Identifiable {
        case none = "Aucun"
        case blackWhite = "Noir et blanc"
        case sepia = "Sépia"
        case vivid = "Éclatant"
        case fade = "Doux"
        case chrome = "Chrome"
        var id: String { rawValue }
    }

    var auto = false            // « J'ai de la chance » : corrections automatiques Core Image
    var exposure = 0.0          // -2 … +2 IL
    var contrast = 0.0          // -1 … +1
    var saturation = 0.0        // -1 … +1
    var warmth = 0.0            // -1 (froid) … +1 (chaud)
    var highlights = 0.0        // -1 … +1 (récupère les hautes lumières)
    var shadows = 0.0           // -1 … +1 (débouche les ombres)
    var straighten = 0.0        // degrés, -15 … +15
    var filter: Filter = .none
    /// Recadrage relatif (0–1) dans l'image orientée et pivotée, origine en haut à gauche.
    var cropX = 0.0, cropY = 0.0, cropW = 1.0, cropH = 1.0

    var crop: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropW, height: cropH) }
        set { (cropX, cropY, cropW, cropH) = (newValue.minX, newValue.minY, newValue.width, newValue.height) }
    }

    var hasCrop: Bool { cropX > 0.0005 || cropY > 0.0005 || cropW < 0.999 || cropH < 0.999 }

    var isIdentity: Bool {
        !auto && exposure == 0 && contrast == 0 && saturation == 0 && warmth == 0 && highlights == 0
            && shadows == 0 && straighten == 0 && filter == .none && !hasCrop
    }

    /// Clé courte pour les caches de miniatures.
    var cacheKey: String { isIdentity ? "" : String(hashValue, radix: 36) }
}

/// Applique les retouches avec Core Image (GPU).
enum EditRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: CGImage, _ e: PhotoEdits?, cropping: Bool = true) -> CGImage {
        guard let e, !e.isIdentity else { return image }
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if e.auto {
            for f in ci.autoAdjustmentFilters(options: [.redEye: false]) {
                f.setValue(ci, forKey: kCIInputImageKey)
                if let out = f.outputImage { ci = out }
            }
        }
        if e.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = ci
            f.ev = Float(e.exposure)
            ci = f.outputImage ?? ci
        }
        if e.highlights != 0 || e.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = ci
            f.highlightAmount = Float(1 - max(0, e.highlights))
            f.shadowAmount = Float(e.shadows)
            ci = f.outputImage ?? ci
        }
        if e.contrast != 0 || e.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = ci
            f.contrast = Float(1 + e.contrast * 0.5)
            f.saturation = Float(1 + e.saturation)
            ci = f.outputImage ?? ci
        }
        if e.warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = ci
            f.neutral = CIVector(x: 6500 - CGFloat(e.warmth) * 2500, y: 0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            ci = f.outputImage ?? ci
        }
        switch e.filter {
        case .none: break
        case .blackWhite: ci = ci.applyingFilter("CIPhotoEffectMono")
        case .sepia: ci = ci.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        case .vivid: ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
        case .fade: ci = ci.applyingFilter("CIPhotoEffectFade")
        case .chrome: ci = ci.applyingFilter("CIPhotoEffectChrome")
        }
        ci = ci.cropped(to: extent)

        if e.straighten != 0 {
            // CIStraightenFilter tourne et agrandit pour éviter les coins vides.
            ci = ci.applyingFilter("CIStraightenFilter", parameters: [kCIInputAngleKey: -e.straighten * .pi / 180])
                .cropped(to: extent)
        }
        if cropping, e.hasCrop {
            // Repère Core Image : origine en bas à gauche.
            let r = CGRect(x: extent.minX + e.cropX * extent.width,
                           y: extent.minY + (1 - e.cropY - e.cropH) * extent.height,
                           width: e.cropW * extent.width, height: e.cropH * extent.height).integral
            ci = ci.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        return context.createCGImage(ci, from: ci.extent.integral) ?? image
    }
}
