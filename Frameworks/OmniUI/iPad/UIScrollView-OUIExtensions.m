// Copyright 2010-2013 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniUI/UIScrollView-OUIExtensions.h>

#import <OmniFoundation/OFExtent.h>
#import <OmniUI/OUIDragGestureRecognizer.h>

#import "OUIParameters.h"

RCS_ID("$Id$");

#if 0 && defined(DEBUG)
    #define DEBUG_AUTOSCROLL(format, ...) NSLog(@"AUTOSCROLL: " format, ## __VA_ARGS__)
#else
    #define DEBUG_AUTOSCROLL(format, ...) do {} while (0)
#endif

@implementation UIScrollView (OUIExtensions)

#if defined(OMNI_ASSERTIONS_ON)

static void (*_original_setContentOffsetAnimated)(UIScrollView *self, SEL _cmd, CGPoint contentOffset, BOOL animated) = NULL;
static void (*_original_setContentOffset)(UIScrollView *self, SEL _cmd, CGPoint contentOffset) = NULL;

static BOOL checkValue(CGFloat v)
{
    OBASSERT(!isnan(v));
    OBASSERT(!isinf(v));
    return YES;
}

static void _replacement_setContentOffsetAnimated(UIScrollView *self, SEL _cmd, CGPoint contentOffset, BOOL animated)
{
    OBASSERT(checkValue(contentOffset.x));
    OBASSERT(checkValue(contentOffset.y));
    _original_setContentOffsetAnimated(self, _cmd, contentOffset, animated);
}

static void _replacement_setContentOffset(UIScrollView *self, SEL _cmd, CGPoint contentOffset)
{
    OBASSERT(checkValue(contentOffset.x));
    OBASSERT(checkValue(contentOffset.y));
    _original_setContentOffset(self, _cmd, contentOffset);
}

static void OUIScrollViewPerformPosing(void) __attribute__((constructor));
static void OUIScrollViewPerformPosing(void)
{
    Class viewClass = NSClassFromString(@"UIScrollView");

    _original_setContentOffsetAnimated = (typeof(_original_setContentOffsetAnimated))OBReplaceMethodImplementation(viewClass, @selector(setContentOffset:animated:), (IMP)_replacement_setContentOffsetAnimated);
    _original_setContentOffset = (typeof(_original_setContentOffset))OBReplaceMethodImplementation(viewClass, @selector(setContentOffset:), (IMP)_replacement_setContentOffset);
}

#endif

#define kDragAutoscrollTimerFrequency (60.0)

// The calling code has to manage the timer and should use this interval.
- (NSTimeInterval)autoscrollTimerInterval;
{
    return 1/kDragAutoscrollTimerFrequency;
}

static NSUInteger _adjustAllowedDirections(UIScrollView *self, UIGestureRecognizer *recognizer, NSUInteger allowedDirections)
{
    // Probably is, but it might be useful to let other recognizers do this somehow.
    if (![recognizer isKindOfClass:[OUIDragGestureRecognizer class]])
        return allowedDirections;
    OUIDragGestureRecognizer *drag = (OUIDragGestureRecognizer *)recognizer;
    
    // If we haven't overcome hysteresis, we don't want to start dragging, even if the touch location is in the drag done.
    // Also, if the object you are dragging is near the edge, we don't want to start dragging the wrong way. That is, if it is at the top, and you drag *down* (away from the top) enough to overcome hysteresis, but still w/in the drag zone, we don't want to drag that direction.
    // In some situations, it might not be possible to drag enough to break hysteresis in the direction you want to drag (if you are close to the edge), so we disable directions that are opposite to the direction of the drag.

    if (![drag overcameHysteresis])
        return 0; // No allowed drag directions
    
    // Don't autoscroll in directions that have all the room they need. Might need to adjust for content inset here, but haven't needed it yet.
    CGRect bounds = self.bounds;
    CGSize contentSize = self.contentSize;
        
    if (bounds.size.width >= contentSize.width)
        allowedDirections &= ~(OUIAutoscrollDirectionLeft|OUIAutoscrollDirectionRight);
    if (bounds.size.height >= contentSize.height)
        allowedDirections &= ~(OUIAutoscrollDirectionUp|OUIAutoscrollDirectionDown);
    
    // Might need to be smarter about this, but possibly not. For example, if you are against the top edge and drag right enough, your delta-y could be a small positive or negative number and you'd start scrolling up. That seems reasonable though. If you meant to go down, you'd definitely have a positive y delta by this time.
    CGPoint delta = [drag cumulativeOffsetInView:self];

    if (delta.x > 0)
        allowedDirections &= ~OUIAutoscrollDirectionLeft;
    else if (delta.x < 0)
        allowedDirections &= ~OUIAutoscrollDirectionRight;
    
    if (delta.y > 0)
        allowedDirections &= ~OUIAutoscrollDirectionUp;
    else if (delta.y < 0)
        allowedDirections &= ~OUIAutoscrollDirectionDown;
    
    return allowedDirections;
}

static CGRect _nonautoscrollBounds(UIScrollView *self, NSUInteger allowedDirections)
{
    UIEdgeInsets insets;
    insets.left = (allowedDirections & OUIAutoscrollDirectionLeft) ? kOUIAutoscrollBorderWidth : 0;
    insets.right = (allowedDirections & OUIAutoscrollDirectionRight) ? kOUIAutoscrollBorderWidth : 0;
    insets.top = (allowedDirections & OUIAutoscrollDirectionUp) ? kOUIAutoscrollBorderWidth : 0;
    insets.bottom = (allowedDirections & OUIAutoscrollDirectionDown) ? kOUIAutoscrollBorderWidth : 0;
    
    return UIEdgeInsetsInsetRect(self.bounds, insets);
}

- (BOOL)shouldAutoscrollWithRecognizer:(UIGestureRecognizer *)recognizer allowedDirections:(NSUInteger)allowedDirections;
{
    allowedDirections = _adjustAllowedDirections(self, recognizer, allowedDirections);
    
    CGRect nonAutoscrollBounds = _nonautoscrollBounds(self, allowedDirections);

    CGPoint pt = [recognizer locationInView:self];
    
    // TODO: Later we may want the caller to pass in the allowed scroll directions
    return CGRectContainsPoint(nonAutoscrollBounds, pt) == NO;
}

- (BOOL)shouldAutoscrollWithRecognizer:(UIGestureRecognizer *)recognizer;
{
    return [self shouldAutoscrollWithRecognizer:recognizer allowedDirections:(OUIAutoscrollDirectionLeft|OUIAutoscrollDirectionRight|OUIAutoscrollDirectionUp|OUIAutoscrollDirectionDown)];
}

static CGFloat stepSize(CGFloat a, CGFloat b)
{
    CGFloat maximumPixelsPerTimer = kOUIAutoscrollMaximumVelocity / kDragAutoscrollTimerFrequency; // kOUIAutoscrollMaximumVelocity is in pixels per second.

    CGFloat fraction = fabs(a - b) / kOUIAutoscrollBorderWidth;

    fraction = pow(fraction, kOUIAutoscrollVelocityRampPower);
    
    return floor(fraction * maximumPixelsPerTimer);
}

// Should only be called if -shouldAutoscrollWithRecognizer:allowedDirections: reported YES and should be called with the same directions. Returns the delta which was applied to the content offset of the receiver.
- (CGPoint)performAutoscrollWithRecognizer:(UIGestureRecognizer *)recognizer allowedDirections:(NSUInteger)allowedDirections;
{
    allowedDirections = _adjustAllowedDirections(self, recognizer, allowedDirections);

    CGPoint contentOffset = self.contentOffset;
    UIEdgeInsets contentInset = self.contentInset;
    CGSize contentSize = self.contentSize;
    
    DEBUG_AUTOSCROLL(@"autoscroll content size %@, offset %@, insets %@", NSStringFromCGSize(contentSize), NSStringFromCGPoint(contentOffset), NSStringFromUIEdgeInsets(contentInset));
        
    CGPoint touch = [recognizer locationInView:self];
    CGPoint step = CGPointZero;
    
    CGRect nonAutoscrollBounds = _nonautoscrollBounds(self, allowedDirections);

    if ((allowedDirections & OUIAutoscrollDirectionLeft) && touch.x < CGRectGetMinX(nonAutoscrollBounds)) {
        step.x = -stepSize(CGRectGetMinX(nonAutoscrollBounds), touch.x);
    } else if ((allowedDirections & OUIAutoscrollDirectionRight) && touch.x > CGRectGetMaxX(nonAutoscrollBounds)) {
        step.x = stepSize(touch.x, CGRectGetMaxX(nonAutoscrollBounds));
    }

    if ((allowedDirections & OUIAutoscrollDirectionUp) && touch.y < CGRectGetMinY(nonAutoscrollBounds)) {
        step.y = -stepSize(CGRectGetMinY(nonAutoscrollBounds), touch.y);
    } else if ((allowedDirections & OUIAutoscrollDirectionDown) && touch.y > CGRectGetMaxY(nonAutoscrollBounds)) {
        step.y = stepSize(touch.y, CGRectGetMaxY(nonAutoscrollBounds));
    }

    // Not sure the content inset here is a general rule, but in OO/iPad this prevents scrolling past the far edge loading indicators. We might want to over-drag in some cases...
    OFExtent allowedXContentOffset = OFExtentFromLocations(-contentInset.left, contentSize.width - self.bounds.size.width + contentInset.right);
    OFExtent allowedYContentOffset = OFExtentFromLocations(-contentInset.top, contentSize.height - self.bounds.size.height + contentInset.bottom);
    
    CGPoint updatedContentOffset;
    updatedContentOffset.x = OFExtentClampValue(allowedXContentOffset, contentOffset.x + step.x);
    updatedContentOffset.y = OFExtentClampValue(allowedYContentOffset, contentOffset.y + step.y);
    
    if (CGPointEqualToPoint(contentOffset, updatedContentOffset) == NO) {
        DEBUG_AUTOSCROLL(@"  step %@", NSStringFromCGPoint(step));
        self.contentOffset = updatedContentOffset;
        
        return CGPointMake(updatedContentOffset.x - contentOffset.x, updatedContentOffset.y - contentOffset.y);
    }
    
    return CGPointZero;
}

@end
