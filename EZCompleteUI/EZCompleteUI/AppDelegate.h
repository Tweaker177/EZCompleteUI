//
//  AppDelegate.h
//  EZCompleteUI
//
//  Created by Brian A Nooning on 3/16/26.
//

#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (readonly, strong) NSPersistentContainer *persistentContainer;


@end

