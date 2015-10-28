/*****************************************************************************
 * VLCNetworkServerBrowserViewController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013-2015 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *          Pierre SAGASPE <pierre.sagaspe # me.com>
 *          Tobias Conradi <videolan # tobias-conradi.de>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCNetworkServerBrowserViewController.h"
#import "VLCNetworkListCell.h"
#import "VLCActivityManager.h"
#import "VLCStatusLabel.h"
#import "VLCPlaybackController.h"
#import "VLCDownloadViewController.h"
#import "UIDevice+VLC.h"
#import "NSString+SupportedMedia.h"
#import "UIDevice+VLC.h"

#import "VLCNetworkServerBrowser-Protocol.h"

@interface VLCNetworkServerBrowserViewController () <VLCNetworkServerBrowserDelegate,VLCNetworkListCellDelegate, UITableViewDataSource, UITableViewDelegate, UIActionSheetDelegate>
{
    UIRefreshControl *_refreshControl;
}
@property (nonatomic) id<VLCNetworkServerBrowser> serverBrowser;
@property (nonatomic) NSByteCountFormatter *byteCounterFormatter;
@property (nonatomic) NSArray<id<VLCNetworkServerBrowserItem>> *searchArray;
@end

@implementation VLCNetworkServerBrowserViewController

- (instancetype)initWithServerBrowser:(id<VLCNetworkServerBrowser>)browser
{
    self = [super init];
    if (self) {
        _serverBrowser = browser;
        browser.delegate = self;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _refreshControl = [[UIRefreshControl alloc] init];
    _refreshControl.backgroundColor = [UIColor VLCDarkBackgroundColor];
    _refreshControl.tintColor = [UIColor whiteColor];
    [_refreshControl addTarget:self action:@selector(handleRefresh) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:_refreshControl];

    self.title = self.serverBrowser.title;
    [self update];
}

- (void)networkServerBrowserDidUpdate:(id<VLCNetworkServerBrowser>)networkBrowser {
    [self.tableView reloadData];
    [[VLCActivityManager defaultManager] networkActivityStopped];
    [_refreshControl endRefreshing];
}

- (void)networkServerBrowser:(id<VLCNetworkServerBrowser>)networkBrowser requestDidFailWithError:(NSError *)error {

    [self vlc_showAlertWithTitle:NSLocalizedString(@"LOCAL_SERVER_CONNECTION_FAILED_TITLE", nil)
                         message:NSLocalizedString(@"LOCAL_SERVER_CONNECTION_FAILED_MESSAGE", nil)
                     buttonTitle:NSLocalizedString(@"BUTTON_CANCEL", nil)];
}

- (void)update
{
    [self.serverBrowser update];
    [[VLCActivityManager defaultManager] networkActivityStarted];
}

-(void)handleRefresh
{
    //set the title while refreshing
    _refreshControl.attributedTitle = [[NSAttributedString alloc] initWithString:NSLocalizedString(@"LOCAL_SERVER_REFRESH",nil)];
    //set the date and time of refreshing
    NSDateFormatter *formattedDate = [[NSDateFormatter alloc]init];
    [formattedDate setDateFormat:@"MMM d, h:mm a"];
    NSString *lastupdated = [NSString stringWithFormat:NSLocalizedString(@"LOCAL_SERVER_LAST_UPDATE",nil),[formattedDate stringFromDate:[NSDate date]]];
    NSDictionary *attrsDictionary = [NSDictionary dictionaryWithObject:[UIColor whiteColor] forKey:NSForegroundColorAttributeName];
    _refreshControl.attributedTitle = [[NSAttributedString alloc] initWithString:lastupdated attributes:attrsDictionary];
    //end the refreshing

    [self update];
}

#pragma mark -
- (NSByteCountFormatter *)byteCounterFormatter {
    if (!_byteCounterFormatter) {
        _byteCounterFormatter = [[NSByteCountFormatter alloc] init];
    }
    return _byteCounterFormatter;
}

#pragma mark - server browser item specifics

- (void)_downloadItem:(id<VLCNetworkServerBrowserItem>)item
{
    NSString *filename = item.name;
    if (filename.pathExtension.length == 0) {
        /* there are few crappy UPnP servers who don't reveal the correct file extension, so we use a generic fake (#11123) */
        NSString *urlExtension = item.URL.pathExtension;
        NSString *extension = urlExtension.length != 0 ? urlExtension : @"vlc";
        filename = [filename stringByAppendingPathExtension:extension];
    }
    [[VLCDownloadViewController sharedInstance] addURLToDownloadList:item.URL
                                                     fileNameOfMedia:filename];
}

- (BOOL)triggerDownloadForItem:(id<VLCNetworkServerBrowserItem>)item
{
    if (item.fileSizeBytes.longLongValue  < [[UIDevice currentDevice] freeDiskspace].longLongValue) {
        [self _downloadItem:item];
        return YES;
    } else {
        NSString *title = NSLocalizedString(@"DISK_FULL", nil);
        NSString *messsage = [NSString stringWithFormat:NSLocalizedString(@"DISK_FULL_FORMAT", nil), item.name, [[UIDevice currentDevice] model]];
        NSString *button = NSLocalizedString(@"BUTTON_OK", nil);
        [self vlc_showAlertWithTitle:title message:messsage buttonTitle:button];
        return NO;
    }
}



- (void)didSelectItem:(id<VLCNetworkServerBrowserItem>)item index:(NSUInteger)index singlePlayback:(BOOL)singlePlayback
{
    if (item.isContainer) {
        VLCNetworkServerBrowserViewController *targetViewController = [[VLCNetworkServerBrowserViewController alloc] initWithServerBrowser:item.containerBrowser];
        [self.navigationController pushViewController:targetViewController animated:YES];
    } else {
        if (singlePlayback) {
            [self _streamFileForItem:item];
        } else {
            VLCMediaList *mediaList = self.serverBrowser.mediaList;
            [self configureSubtitlesInMediaList:mediaList];
            [self _streamMediaList:mediaList startingAtIndex:index];
        }
    }
}


- (void)configureSubtitlesInMediaList:(VLCMediaList *)mediaList {
    NSArray *items = self.serverBrowser.items;
    id<VLCNetworkServerBrowserItem> loopItem;
    [mediaList lock];
    NSUInteger count = mediaList.count;
    for (NSUInteger i = 0; i < count; i++) {
        loopItem = items[i];
        NSString *URLofSubtitle = nil;
        NSURL *remoteSubtitleURL = nil;
        if ([loopItem respondsToSelector:@selector(subtitleURL)]) {
            [loopItem subtitleURL];
        }
        if (remoteSubtitleURL == nil) {
            NSArray *subtitlesList = [self _searchSubtitle:loopItem.URL.lastPathComponent];
            remoteSubtitleURL = subtitlesList.firstObject;
        }

        if(remoteSubtitleURL != nil) {
            URLofSubtitle = [self _getFileSubtitleFromServer:remoteSubtitleURL];
            if (URLofSubtitle != nil)
                [[mediaList mediaAtIndex:i] addOptions:@{ kVLCSettingSubtitlesFilePath : URLofSubtitle }];
        }
    }
    [mediaList unlock];
}


- (NSString *)_getFileSubtitleFromServer:(NSURL *)subtitleURL
{
    NSString *FileSubtitlePath = nil;
    NSData *receivedSub = [NSData dataWithContentsOfURL:subtitleURL]; // TODO: fix synchronous load

    if (receivedSub.length < [[UIDevice currentDevice] freeDiskspace].longLongValue) {
        NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *directoryPath = searchPaths[0];
        FileSubtitlePath = [directoryPath stringByAppendingPathComponent:[subtitleURL lastPathComponent]];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:FileSubtitlePath]) {
            //create local subtitle file
            [fileManager createFileAtPath:FileSubtitlePath contents:nil attributes:nil];
            if (![fileManager fileExistsAtPath:FileSubtitlePath]) {
                APLog(@"file creation failed, no data was saved");
                return nil;
            }
        }
        [receivedSub writeToFile:FileSubtitlePath atomically:YES];
    } else {

        [self vlc_showAlertWithTitle:NSLocalizedString(@"DISK_FULL", nil)
                                            message:[NSString stringWithFormat:NSLocalizedString(@"DISK_FULL_FORMAT", nil), [subtitleURL lastPathComponent], [[UIDevice currentDevice] model]]
                                        buttonTitle:NSLocalizedString(@"BUTTON_OK", nil)];
    }
    
    return FileSubtitlePath;
}

- (void)_streamMediaList:(VLCMediaList *)mediaList startingAtIndex:(NSInteger)startIndex
{
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    [vpc playMediaList:mediaList firstIndex:startIndex];
}

- (void)_streamFileForItem:(id<VLCNetworkServerBrowserItem>)item
{
    NSString *URLofSubtitle = nil;
    NSURL *remoteSubtitleURL = nil;
    if ([item respondsToSelector:@selector(subtitleURL)]) {
        remoteSubtitleURL = [item subtitleURL];
    }
    if (!remoteSubtitleURL) {
        NSArray *SubtitlesList = [self _searchSubtitle:item.URL.lastPathComponent];
        remoteSubtitleURL = SubtitlesList.firstObject;
    }

    if(remoteSubtitleURL)
        URLofSubtitle = [self _getFileSubtitleFromServer:remoteSubtitleURL];

    NSURL *URLToPlay = item.URL;

    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    [vpc playURL:URLToPlay subtitlesFilePath:URLofSubtitle];
}

- (NSArray<NSURL*> *)_searchSubtitle:(NSString *)url
{
    NSString *urlTemp = [[url lastPathComponent] stringByDeletingPathExtension];

    NSMutableArray<NSURL*> *urls = [NSMutableArray arrayWithArray:[self.serverBrowser.items valueForKey:@"URL"]];

    NSPredicate *namePredicate = [NSPredicate predicateWithFormat:@"SELF.path contains[c] %@", urlTemp];
    [urls filterUsingPredicate:namePredicate];

    NSPredicate *formatPrediate = [NSPredicate predicateWithBlock:^BOOL(NSURL *_Nonnull evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
        return [evaluatedObject.path isSupportedSubtitleFormat];
    }];
    [urls filterUsingPredicate:formatPrediate];

    return [NSArray arrayWithArray:urls];
}


#pragma mark - table view data source, for more see super

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (tableView == self.searchDisplayController.searchResultsTableView)
        return _searchArray.count;

    return self.serverBrowser.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    VLCNetworkListCell *cell = (VLCNetworkListCell *)[tableView dequeueReusableCellWithIdentifier:VLCNetworkListCellIdentifier];
    if (cell == nil)
        cell = [VLCNetworkListCell cellWithReuseIdentifier:VLCNetworkListCellIdentifier];


    id<VLCNetworkServerBrowserItem> item;
    if (tableView == self.searchDisplayController.searchResultsTableView) {
        item = _searchArray[indexPath.row];
    } else {
        item = self.serverBrowser.items[indexPath.row];
    }

    cell.title = item.name;

    if (item.isContainer) {
        cell.isDirectory = YES;
        cell.icon = [UIImage imageNamed:@"folder"];
    } else {
        cell.isDirectory = NO;
        cell.icon = [UIImage imageNamed:@"blank"];

        NSString *sizeString = item.fileSizeBytes ? [self.byteCounterFormatter stringFromByteCount:item.fileSizeBytes.longLongValue] : nil;

        NSString *duration = nil;
        if ([item respondsToSelector:@selector(duration)]) {
            duration = item.duration;
        }

        NSString *subtitle = nil;
        if (sizeString && duration) {
            subtitle = [NSString stringWithFormat:@"%@ (%@)",sizeString, duration];
        } else if (sizeString) {
            subtitle = sizeString;
        } else if (duration) {
            subtitle = duration;
        }
        cell.subtitle = sizeString;
        cell.isDownloadable = YES;
        cell.delegate = self;

        NSURL *thumbnailURL = nil;
        if ([item respondsToSelector:@selector(thumbnailURL)]) {
            thumbnailURL = item.thumbnailURL;
        }

        if (thumbnailURL) {
            [cell setIconURL:thumbnailURL];
        }
    }

    return cell;
}

#pragma mark - table view delegate, for more see super

- (void)tableView:(UITableView *)tableView willDisplayCell:(VLCNetworkListCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];

    if([indexPath row] == ((NSIndexPath*)[[tableView indexPathsForVisibleRows] lastObject]).row)
        [[VLCActivityManager defaultManager] networkActivityStopped];
}


- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    id<VLCNetworkServerBrowserItem> item;
    NSInteger row = indexPath.row;
    BOOL singlePlayback = NO;
    if (tableView == self.searchDisplayController.searchResultsTableView) {
        item = _searchArray[row];
        singlePlayback = YES;
    } else {
        item = self.serverBrowser.items[row];
    }

    [self didSelectItem:item index:row singlePlayback:singlePlayback];

    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}


#pragma mark - VLCNetworkListCell delegation
- (void)triggerDownloadForCell:(VLCNetworkListCell *)cell
{
    id<VLCNetworkServerBrowserItem> item;
    if ([self.searchDisplayController isActive])
        item = _searchArray[[self.searchDisplayController.searchResultsTableView indexPathForCell:cell].row];
    else
        item = self.serverBrowser.items[[self.tableView indexPathForCell:cell].row];

    if ([self triggerDownloadForItem:item]) {
        [cell.statusLabel showStatusMessage:NSLocalizedString(@"DOWNLOADING", nil)];
    }
}


#pragma mark - search

- (BOOL)searchDisplayController:(UISearchDisplayController *)controller shouldReloadTableForSearchString:(NSString *)searchString
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name contains[c] %@",searchString];
    self.searchArray = [self.serverBrowser.items filteredArrayUsingPredicate:predicate];
    return YES;
}

@end