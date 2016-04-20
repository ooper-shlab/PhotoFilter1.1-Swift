//
//  AAPLPhotoEditingViewController.swift
//  Photo Filter
//
//  Created by 開発 on 2014/08/11.
//
//
/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:

  The view controller of the photo editing extension.

 */

import UIKit
import CoreMedia

import AVFoundation
import CoreImage
import Photos
import PhotosUI


let kFilterInfoFilterNameKey = "filterName"
let kFilterInfoDisplayNameKey = "displayName"
let kFilterInfoPreviewImageKey = "previewImage"


@objc(AAPLPhotoEditingViewController)
class PhotoEditingViewController : UIViewController,
    PHContentEditingController, UICollectionViewDataSource,
UICollectionViewDelegate, AVReaderWriterAdjustDelegate {
    
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var filterPreviewView: UIImageView!
    @IBOutlet weak var backgroundImageView: UIImageView!
    
    private final var availableFilterInfos: NSArray!
    private final var selectedFilterName: String!
    private final var initialFilterName: String!
    
    private final var inputImage: UIImage!
    private final var ciFilter: CIFilter!
    private final var ciContext: CIContext!
    
    private final var contentEditingInput: PHContentEditingInput!
    
    
    //MARK: - UIViewController
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Setup collection view
        collectionView.alwaysBounceHorizontal = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsSelection = true
        
        // Load the available filters
        let plist = NSBundle.mainBundle().pathForResource("Filters", ofType: "plist")
        availableFilterInfos = NSArray(contentsOfFile: plist!)
        
        ciContext = CIContext(options: nil)
        
        // Add the background image and UIEffectView for the blur
        let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .Dark))
        effectView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(effectView, aboveSubview:backgroundImageView)
        
        let verticalConstraints = NSLayoutConstraint.constraintsWithVisualFormat("V:|[effectView]|", options: [], metrics: nil, views: ["effectView": effectView])
        let horizontalConstraints = NSLayoutConstraint.constraintsWithVisualFormat("H:|[effectView]|", options: [], metrics: nil, views: ["effectView": effectView])
        view.addConstraints(verticalConstraints)
        view.addConstraints(horizontalConstraints)
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        // Update the selection UI
        let item = availableFilterInfos.indexOfObjectPassingTest {filterInfo, idx, stop in
            filterInfo[kFilterInfoFilterNameKey] as? NSString == self.selectedFilterName
        }
        if item != NSNotFound {
            let indexPath = NSIndexPath(forItem: item, inSection: 0)
            collectionView.selectItemAtIndexPath(indexPath, animated: false, scrollPosition: .CenteredHorizontally)
            updateSelectionForCell(collectionView.cellForItemAtIndexPath(indexPath))
        }
    }
    
    
    //MARK: - PHContentEditingController
    
    func canHandleAdjustmentData(adjustmentData: PHAdjustmentData!)->Bool {
        var result = adjustmentData.formatIdentifier == "com.example.apple-samplecode.photofilter"
        result = result && adjustmentData.formatVersion == "1.0"
        return result
    }
    
    func startContentEditingWithInput(contentEditingInput: PHContentEditingInput, placeholderImage: UIImage!) {
        self.contentEditingInput = contentEditingInput
        
        // Load input image
        switch contentEditingInput.mediaType {
        case .Image:
            self.inputImage = self.contentEditingInput.displaySizeImage
            
        case .Video:
            self.inputImage = imageForAVAsset(self.contentEditingInput.avAsset, atTime:0.0)
            
        default:
            break
        }
        
        // Load adjustment data, if any
        let adjustmentData = self.contentEditingInput.adjustmentData
        self.selectedFilterName = NSKeyedUnarchiver.unarchiveObjectWithData(adjustmentData.data) as! String?
        if selectedFilterName == nil {
            let defaultFilterName = "CISepiaTone"
            selectedFilterName = defaultFilterName
        }
        initialFilterName = selectedFilterName
        
        // Update filter and background image
        updateFilter()
        updateFilterPreview()
        backgroundImageView.image = placeholderImage
    }
    
    func finishContentEditingWithCompletionHandler(completionHandler: PHContentEditingOutput!->Void) {
        let contentEditingOutput = PHContentEditingOutput(contentEditingInput: self.contentEditingInput)
        
        // Adjustment data
        let archivedData = NSKeyedArchiver.archivedDataWithRootObject(selectedFilterName)
        let adjustmentData = PHAdjustmentData(formatIdentifier: "com.example.apple-samplecode.photofilter", formatVersion: "1.0", data: archivedData)
        contentEditingOutput.adjustmentData = adjustmentData
        
        switch self.contentEditingInput.mediaType {
        case .Image:
            // Get full size image
            let url = self.contentEditingInput.fullSizeImageURL
            let orientation = self.contentEditingInput.fullSizeImageOrientation
            
            // Generate rendered JPEG data
            var image = UIImage(contentsOfFile: url!.path!)
            image = transformedImage(image, withOrientation:orientation, usingFilter:ciFilter)
            let renderedJPEGData = UIImageJPEGRepresentation(image!, 0.9)
            
            // Save JPEG data
            do {
                try renderedJPEGData!.writeToURL(contentEditingOutput.renderedContentURL, options: .DataWritingAtomic)
                completionHandler(contentEditingOutput)
            } catch let error as NSError {
                NSLog("An error occured: %@", error);
                completionHandler(nil)
            }
            
        case .Video:
            // Get AV asset
            let avReaderWriter = AVReaderWriter(asset: contentEditingInput.avAsset!)
            avReaderWriter.delegate = self
            
            // Save filtered video
            avReaderWriter.writeToURL(contentEditingOutput.renderedContentURL, progress: {progress in
                }) {error in
                    if error == nil {
                        completionHandler(contentEditingOutput)
                    } else {
                        NSLog("An error occured: %@", error!)
                        completionHandler(nil)
                    }
            }
            
        default:
            break
        }
        
    }
    
    func cancelContentEditing() {
        // Handle cancellation
    }
    
    var shouldShowCancelConfirmation: Bool {
        var shouldShow = false
        
        if selectedFilterName != initialFilterName {
            shouldShow = true
        }
        
        return shouldShow
    }
    
    //MARK: - Image Filtering
    
    func updateFilter() {
        ciFilter = CIFilter(name: selectedFilterName)
        
        var inputImage = CIImage(CGImage: self.inputImage.CGImage!)
        let orientation = orientationFromImageOrientation(self.inputImage.imageOrientation)
        inputImage = inputImage.imageByApplyingOrientation(Int32(orientation))
        
        ciFilter.setValue(inputImage, forKey: kCIInputImageKey)
    }
    
    func updateFilterPreview() {
        let outputImage = ciFilter.outputImage
        
        let cgImage = ciContext.createCGImage(outputImage!, fromRect: outputImage!.extent)
        let transformedImage = UIImage(CGImage: cgImage)
        
        filterPreviewView.image = transformedImage
    }
    
    func transformedImage(image: UIImage!, withOrientation orientation: Int32, usingFilter filter: CIFilter!)->UIImage! {
        var inputImage = CIImage(CGImage: image.CGImage!)
        inputImage = inputImage.imageByApplyingOrientation(orientation)
        
        ciFilter.setValue(inputImage, forKey: kCIInputImageKey)
        let outputImage = ciFilter.outputImage
        
        let cgImage = ciContext.createCGImage(outputImage!, fromRect: outputImage!.extent)
        let transformedImage = UIImage(CGImage: cgImage)
        
        return transformedImage
    }
    
    //MARK: - AVReaderWriterAdjustDelegate (Video Filtering)
    
    func adjustPixelBuffer(inputBuffer: CVPixelBuffer!, toOutputBuffer outputBuffer: CVPixelBuffer!) {
        var img = CIImage(CVPixelBuffer: inputBuffer)
        
        ciFilter.setValue(img, forKey: kCIInputImageKey)
        img = ciFilter.outputImage!
        
        ciContext.render(img, toCVPixelBuffer: outputBuffer)
    }
    
    //MARK: - UICollectionViewDataSource & UICollectionViewDelegate
    
    func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.availableFilterInfos.count
    }
    
    func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        let filterInfo = availableFilterInfos[indexPath.item] as! NSDictionary
        let displayName = filterInfo[kFilterInfoDisplayNameKey] as! String
        let previewImageName = filterInfo[kFilterInfoPreviewImageKey] as! String
        
        let cell = collectionView.dequeueReusableCellWithReuseIdentifier("PhotoFilterCell", forIndexPath:indexPath) as UICollectionViewCell
        
        let imageView = cell.viewWithTag(999) as! UIImageView
        imageView.image = UIImage(named: previewImageName)
        
        let label = cell.viewWithTag(998) as! UILabel
        label.text = displayName
        
        updateSelectionForCell(cell)
        
        return cell
    }
    
    func collectionView(collectionView: UICollectionView, didSelectItemAtIndexPath indexPath: NSIndexPath) {
        selectedFilterName = availableFilterInfos[indexPath.item][kFilterInfoFilterNameKey] as! String
        updateFilter()
        
        updateSelectionForCell(collectionView.cellForItemAtIndexPath(indexPath))
        
        updateFilterPreview()
    }
    
    func collectionView(collectionView: UICollectionView, didDeselectItemAtIndexPath indexPath: NSIndexPath) {
        updateSelectionForCell(collectionView.cellForItemAtIndexPath(indexPath))
    }
    
    func updateSelectionForCell(cell: UICollectionViewCell!) {
        let isSelected = cell.selected
        
        let imageView = cell.viewWithTag(999) as! UIImageView
        imageView.layer.borderColor = view.tintColor.CGColor
        imageView.layer.borderWidth = isSelected ? 2.0 : 0.0
        
        let label = cell.viewWithTag(998) as! UILabel
        label.textColor = isSelected ? view.tintColor : UIColor.whiteColor()
    }
    
    //MARK: - Utilities
    
    // Returns the EXIF/TIFF orientation value corresponding to the given UIImageOrientation value.
    func orientationFromImageOrientation(imageOrientation: UIImageOrientation)->Int32 {
        var orientation: Int32 = 0;
        switch imageOrientation {
        case .Up:            orientation = 1
        case .Down:          orientation = 3
        case .Left:          orientation = 8
        case .Right:         orientation = 6
        case .UpMirrored:    orientation = 2
        case .DownMirrored:  orientation = 4
        case .LeftMirrored:  orientation = 5
        case .RightMirrored: orientation = 7
        }
        return orientation
    }
    
    func imageForAVAsset(avAsset: AVAsset!, atTime time: NSTimeInterval)->UIImage! {
        let imageGenerator = AVAssetImageGenerator(asset: avAsset)
        imageGenerator.appliesPreferredTrackTransform = true
        let posterImage: CGImage!
        do {
            posterImage = try imageGenerator.copyCGImageAtTime(CMTimeMakeWithSeconds(time, 100), actualTime:nil)
        } catch _ {
            posterImage = nil
        }
        let image = UIImage(CGImage: posterImage)
        return image
    }
    
}