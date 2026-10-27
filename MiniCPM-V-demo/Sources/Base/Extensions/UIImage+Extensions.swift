//
//  UIImage+Rotate.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/7/30.
//

import Foundation
import UIKit

extension UIImage {

    /// Bake `imageOrientation` (EXIF) into pixel data so `cgImage` matches
    /// the visual size. Camera / gallery JPEGs are often stored landscape with
    /// `.right`/`.left`; `UIImageView` applies that flag, but `cgImage` does not.
    func mb_orientedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func rotated(byDegrees degrees: CGFloat) -> UIImage? {
        let radians = degrees * CGFloat.pi / 180
        return rotated(byRadians: radians)
    }

    func rotated(byRadians radians: CGFloat) -> UIImage? {
        // 计算图像旋转后的新尺寸
        var newSize = CGRect(origin: .zero, size: self.size).applying(CGAffineTransform(rotationAngle: radians)).integral.size
        
        // 保持新的尺寸是偶数，以避免使用不一致的像素坐标系
        newSize = CGSize(width: floor(newSize.width), height: floor(newSize.height))
        
        // 在图像上下文中绘制旋转的图像
        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        let context = UIGraphicsGetCurrentContext()!
        
        // 移动原点到图像的中间位置
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        
        // 旋转图像上下文
        context.rotate(by: radians)
        
        // 绘制图像，使其中心对齐到新的原点
        self.draw(in: CGRect(x: -self.size.width / 2, y: -self.size.height / 2, width: self.size.width, height: self.size.height))
        
        // 从上下文中提取图像
        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return rotatedImage
    }
    
    // MARK: - 图片处理
    
    /// 转换成NSData
    @objc func mb_covertToData() -> Data {
        return self.jpegData(compressionQuality: 1.0) ?? Data()
    }
    
    /// 指定宽度按比例缩放
    @objc func mb_imageCompressForWidth(_ sourceImage: UIImage, targetWidth defineWidth: CGFloat) -> UIImage {
        let imageSize = sourceImage.size
        let width = imageSize.width
        let height = imageSize.height
        let targetWidth = defineWidth
        let targetHeight = height / (width / targetWidth)
        let size = CGSize(width: targetWidth, height: targetHeight)
        
        var scaleFactor: CGFloat = 0.0
        var scaledWidth = targetWidth
        var scaledHeight = targetHeight
        var thumbnailPoint = CGPoint.zero
        
        if !imageSize.equalTo(size) {
            let widthFactor = targetWidth / width
            let heightFactor = targetHeight / height
            
            if widthFactor > heightFactor {
                scaleFactor = widthFactor
            } else {
                scaleFactor = heightFactor
            }
            
            scaledWidth = width * scaleFactor
            scaledHeight = height * scaleFactor
            
            if widthFactor > heightFactor {
                thumbnailPoint.y = (targetHeight - scaledHeight) * 0.5
            } else if widthFactor < heightFactor {
                thumbnailPoint.x = (targetWidth - scaledWidth) * 0.5
            }
        }
        
        UIGraphicsBeginImageContext(size)
        var thumbnailRect = CGRect.zero
        thumbnailRect.origin = thumbnailPoint
        thumbnailRect.size.width = scaledWidth
        thumbnailRect.size.height = scaledHeight
        
        sourceImage.draw(in: thumbnailRect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        
        if newImage == nil {
            print("scale image fail")
        }
        
        UIGraphicsEndImageContext()
        return newImage ?? sourceImage
    }
    
    /// 把图片缩放到小于 448x448 大小
    func scaledToSize(targetSize: CGSize) -> UIImage? {
        let originalSize = self.size
        
        var width = originalSize.width
        var height = originalSize.height
        let targetProduct = targetSize.width * targetSize.height
        
        while width * height > targetProduct {
            let scale = sqrt(targetProduct / (width * height))
            width *= scale
            height *= scale
        }
        
        let newSize = CGSize(width: floor(width), height: floor(height))
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        
        let newImage = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
        
        return newImage
    }

}
