//  Copyright (C) 2014 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import <AppKit/AppKit.h>

#import "InAppStore.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, InAppStoreDelegate> {
  NSString* _cachePath;
  NSUInteger _transcoders;
  dispatch_semaphore_t _transcodingSemaphore;
  NSNumberFormatter* _numberFormatter;
  BOOL _cancelled;
}
@property(nonatomic, assign) IBOutlet NSView* accessoryView;
@property(nonatomic, assign) IBOutlet NSWindow* mainWindow;
@property(nonatomic, assign) IBOutlet NSTableView* tableView;
@property(nonatomic, assign) IBOutlet NSArrayController* playlistController;
@property(nonatomic, assign) IBOutlet NSArrayController* trackController;
@property(nonatomic, assign) IBOutlet NSTextField* infoTextField;
@property(nonatomic, getter = isTranscoding) BOOL transcoding;
@end

@interface AppDelegate (Actions)
- (IBAction)updatePlaylist:(id)sender;
- (IBAction)updateQuality:(id)sender;
- (IBAction)updateSkip:(id)sender;
- (IBAction)burnDisc:(id)sender;
- (IBAction)cancelTranscoding:(id)sender;
- (IBAction)purchaseFeature:(id)sender;
- (IBAction)restorePurchases:(id)sender;
@end
