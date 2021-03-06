//
//  ZWDownloadOperate.m
//  ZWDownloadDemo
//
//  Created by Admin on 2020/5/18.
//  Copyright © 2020 ZW. All rights reserved.
//

#import "ZWDownloadOperate.h"
#import "ZWDownloadDefine.h"
#import "ZWFileOperate.h"

@interface ZWDownloadOperate()<NSURLSessionDelegate>

// 保存下载模型的键值对字典，方便通过taskIdentifier直接获取模型
@property (nonatomic, strong) NSMutableDictionary *downloadModelDicts;

// 暂停的任务
@property (nonatomic, strong) NSMutableArray<ZWDownloadModel *> *pausedTasks;

// 进行中的任务
@property (nonatomic, strong) NSMutableArray<ZWDownloadModel *> *downLoadingTasks;

// 等待中任务
@property (nonatomic, strong) NSMutableArray<ZWDownloadModel *> *waitingTasks;

@end

@implementation ZWDownloadOperate

#pragma mark - Public

+ (instancetype)sharedInstance {
    static ZWDownloadOperate  *share = nil;
    static dispatch_once_t pre = 0;
    dispatch_once(&pre, ^{
        share = [[ZWDownloadOperate alloc] init];
        share.maxConcurrentCount = 2;
    });
    
    return share;
}

// 根据模型下载
- (void)addDownLoadWithModel:(ZWDownloadModel *) model
                  preOperate:(void(^)(void)) preOperateBlock
                    progress:(ProgressBlock) progressBlock
                       state:(void (^)(ZWDownloadState, NSError * _Nullable))stateBlock {
    
    if (!model.url) return;
    
    // 判断当前任务是否已经存在
    if (![self isTaskExited:model]) {
        
        // 如果当前模型尚未添加到任务中，那么保存该模型
        [self.downloadModelDicts setValue:model forKey:@(model.taskIdentifier).stringValue];
    }
     
    if ([[ZWFileOperate shared] isCompletion:model.url]) {
        model.state = ZWDownloadStateComplete;
        if (model.stateBlock) { model.stateBlock(ZWDownloadStateComplete, nil); }
        stateBlock(ZWDownloadStateComplete, nil);
        if (self.stateChangedBlock) { self.stateChangedBlock(); }
        return;
    }
    
    // 创建缓存目录文件
    [[ZWFileOperate shared] createCacheDirectory];
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:[[NSOperationQueue alloc] init]];

    // 下载文件保存路径
    NSString *filePath = [[ZWFileOperate shared] getCurrFilePath:model.url];
    model.filePath = filePath;
    
    // 创建流
    NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:filePath append:YES];

    // 创建请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:model.url]];

    // 设置请求头
    NSString *range = [NSString stringWithFormat:@"bytes=%ld-", [[ZWFileOperate shared] getDownloadedLengthWithUrl:model.url]];
    [request setValue:range forHTTPHeaderField:@"Range"];

    // 创建一个Data任务
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    
    // 根据taskIdentifier保存任务的字典的key
    [task setValue:@(model.taskIdentifier) forKeyPath:@"taskIdentifier"];

    model.task = task;
    model.preOperateBlock = preOperateBlock;
    model.progressBlock = progressBlock;
    model.stateBlock = stateBlock;
    model.stream = stream;
    
    [self start:model];
}

// 开始下载
- (void)start:(ZWDownloadModel *)model {
    
    [self addToWaitingTasks:model];
    if (model.isNeedSpeed) {
        model.updateDownloadedLength = 0;
        [model initialTimer];
        dispatch_source_set_event_handler(model.timer, ^{
            [self updateSpeedAndTimeRemainingWithModel:model];
        });
        [model resumeTimerWithFirstTime:true];
    }
    model.state = ZWDownloadStateDownloading;
    if (model.stateBlock) { model.stateBlock(ZWDownloadStateDownloading, nil); }
    model.startDate = [NSDate date];
    if (self.stateChangedBlock) { self.stateChangedBlock(); }
}

// 暂停下载
- (void)pauseDownloadWithModel:(ZWDownloadModel *)model {
    
    [self addToPausedTasks:model];
    if (model.isNeedSpeed) { [model suspendTimer]; }
    model.state = ZWDownloadStateSuspend;
    if (model.stateBlock) { model.stateBlock(ZWDownloadStateSuspend, nil); }
    if (self.stateChangedBlock) { self.stateChangedBlock(); }
}

// 恢复下载
- (void)resumeDownloadWithModel:(ZWDownloadModel *)model {
    
    [self addToWaitingTasks:model];
    if (model.isNeedSpeed) { [model resumeTimerWithFirstTime:false]; }
    model.state = ZWDownloadStateDownloading;
    if (model.stateBlock) { model.stateBlock(ZWDownloadStateDownloading, nil); }
    if (self.stateChangedBlock) { self.stateChangedBlock(); }
}

// 删除下载
- (void)deleteDownloadWithModel:(ZWDownloadModel *)model {
    
    // 删除相关下载文件以及资源
    [[ZWFileOperate shared] deleteFile:model fromDict:self.downloadModelDicts];
    
    [self deleteTask:model];
    
    // 删除定时器
    if (model.isNeedSpeed) {
        [DownloadUtil executeOnSafeMian:^{
            
            [model cancelTimer];
        }];
    }
}

// 取消下载
- (void)cancelDownloadWithModel:(ZWDownloadModel *)model {
    
    // 删除下载相关资源，但是已经下载的文件任然进行保存
    [model.task cancel];
    [model.stream close];
    [self deleteTask:model];
    
    [self.downloadModelDicts removeObjectForKey:@(model.taskIdentifier).stringValue];
    
    // 删除资源总长度
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if ([fileManager fileExistsAtPath:[[ZWFileOperate shared] getDownloadPlistPath]]) {
        
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:[[ZWFileOperate shared] getDownloadPlistPath]];
        
        [dict removeObjectForKey:[[ZWFileOperate shared] getCurrDownloadFileName:model.url]];
        [dict writeToFile:[[ZWFileOperate shared] getDownloadPlistPath] atomically:YES];
    }
    
    // 删除定时器
    if (model.isNeedSpeed) {
        [DownloadUtil executeOnSafeMian:^{
            
            [model cancelTimer];
        }];
    }
}

// 计算下载速度与剩余时间
- (void)updateSpeedAndTimeRemainingWithModel:(ZWDownloadModel *)model {
    
    // 获取当前文件大小
    NSInteger currFileLength = [[ZWFileOperate shared] getDownloadedLengthWithUrl:model.url];
    NSInteger preFileLength = model.updateDownloadedLength;
    
    // 每秒下载的当前文件的大小
    NSInteger deltaLength = currFileLength - preFileLength;
    
    if (deltaLength == 0) {
        
        model.downloadSpeed = @"0Kb/s";
        model.timeRemaining = @"-";
        
    } else {
        
        // 下载速度
        model.downloadSpeed = [NSString stringWithFormat:@"%@/s", [DownloadUtil formatByteCount:deltaLength]];
        
        // 剩余时间
        model.timeRemaining = [DownloadUtil getFormatedTime:(model.totalLength - currFileLength) / deltaLength];
        
        model.updateDownloadedLength = currFileLength;
    }
}

// 获取当前下载的模型
- (ZWDownloadModel *)getDownloadModel:(NSUInteger)taskIdentifier {
    
    return (ZWDownloadModel *)[self.downloadModelDicts valueForKey:@(taskIdentifier).stringValue];
}

// 添加任务到暂停任务数组中(去重)
- (void)addToPausedTasks:(ZWDownloadModel *)model {
    
    // 判断当前任务是否在暂停数组中，如果在那么不做处理
    if ([self.pausedTasks containsObject:model]) {
        [self resumeTaskFromWaitingTasks];
        return;
    }
    
    // 判断是否在等待数组中，如果在那么从等待数组中转移到暂停数组中
    if ([self.waitingTasks containsObject:model]) {
        
        [self.pausedTasks addObject:model];
        [self.waitingTasks removeObject:model];
        [self resumeTaskFromWaitingTasks];
        return;
    }
    
    // 判断是否在下载中数组中
    if ([self.downLoadingTasks containsObject:model]) {
        
        [model.task suspend];
        [self.pausedTasks addObject:model];
        [self.downLoadingTasks removeObject:model];
        [self resumeTaskFromWaitingTasks];
        return;
    }
}

// 添加任务到下载中任务数组中(去重)
- (void)addToDownloadingTasks:(ZWDownloadModel *)model {
    
    // 判断当前任务是否正在下载
    if ([self.downLoadingTasks containsObject:model]) {
        return;
    }
    
    // 判断当前任务是否在等待中(下载中任务只会从等待中任务中获取)
    if ([self.waitingTasks containsObject:model]) {
        
        [self.downLoadingTasks addObject:model];
        [self.waitingTasks removeObject:model];
        return;
    }
}

// 添加任务到等待任务数组中(去重)
- (void)addToWaitingTasks:(ZWDownloadModel *)model {
    
    // 判断当前任务是否在等待中
    if ([self.waitingTasks containsObject:model]) {
        [self resumeTaskFromWaitingTasks];
        return;
    }
    
    // 判断当前任务是否在暂停中
    if ([self.pausedTasks containsObject:model]) {
        
        [self.waitingTasks addObject:model];
        [self.pausedTasks removeObject:model];
        
        [self resumeTaskFromWaitingTasks];
        return;
    }
    
    // 否则是新添加的任务
    [self.waitingTasks addObject:model];
    [self resumeTaskFromWaitingTasks];
}

// 从等待数组中取出任务并开始
- (void)resumeTaskFromWaitingTasks {
    
    // 判断等待数组中是否存在任务
    if (self.waitingTasks.count <= 0) { return; }
    
    // 查看当前的执行任务数量是否达到最大并发数量
    if (self.downLoadingTasks.count >= self.maxConcurrentCount) { return; }
    
    // 将等待数组的第一个任务设置为执行，并且添加到正在下载数组中
    [self.waitingTasks[0].task resume];
    [self addToDownloadingTasks:self.waitingTasks[0]];
}

// 删除指定任务
- (void)deleteTask:(ZWDownloadModel *)model {
    
    if ([self.pausedTasks containsObject:model]) {
        [self.pausedTasks removeObject:model];
    }
    
    if ([self.waitingTasks containsObject:model]) {
        [self.waitingTasks removeObject:model];
    }
    
    if ([self.downLoadingTasks containsObject:model]) {
        [self.downLoadingTasks removeObject:model];
    }
    
    [self resumeTaskFromWaitingTasks];
}

// 判断当前任务是否已经存在
- (BOOL)isTaskExited:(ZWDownloadModel *)model {
    
    NSArray *allKeys = self.downloadModelDicts.allKeys;
    
    return [allKeys containsObject:@(model.taskIdentifier).stringValue];
}

#pragma mark - NSURLSessionDataDelegate 代理

// 接收到响应
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSHTTPURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    
    ZWDownloadModel *downloadModel = [self getDownloadModel:dataTask.taskIdentifier];
    
    // 打开流
    [downloadModel.stream open];
    
    // 获得服务器这次请求 返回数据的总长度
    NSInteger totalLength = [response.allHeaderFields[@"Content-Length"] integerValue] + [[ZWFileOperate shared] getDownloadedLengthWithUrl:downloadModel.url];
    downloadModel.totalLength = totalLength;
    
    NSString *fileName = [[ZWFileOperate shared] getCurrDownloadFileTotalName:downloadModel.url];
    downloadModel.fileName = fileName;
    
    // 存储总长度
    NSDictionary *dict = @{
                            @"totalLength" : @(totalLength),
                            @"url" : downloadModel.url,
                            @"fileName" : fileName
                         };
    
    [[ZWFileOperate shared] setPlistValue:dict forKey:[[ZWFileOperate shared] getCurrDownloadFileName:downloadModel.url]];
    
    // 接收这个请求，允许接收服务器的数据
    completionHandler(NSURLSessionResponseAllow);
    
    // 当打通后立即暂停,并且通知已经获取到当前下载的文件的相关资源
    [self pauseDownloadWithModel:downloadModel];
    
    downloadModel.preOperateBlock();
}

// 接收到服务器返回的数据
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    ZWDownloadModel *downloadModel = [self getDownloadModel:dataTask.taskIdentifier];
    
    // 写入数据
    [downloadModel.stream write:data.bytes maxLength:data.length];
    
    // 已经下载长度
    NSUInteger receivedSize = [[ZWFileOperate shared] getDownloadedLengthWithUrl:downloadModel.url];
    downloadModel.downloadedLength = receivedSize;
    
    // 下载进度
    NSUInteger expectedSize = downloadModel.totalLength;
    CGFloat progress = 1.0 * receivedSize / expectedSize;
    downloadModel.progressBlock(progress, receivedSize, expectedSize);
    
    // 如果是多任务下载，那么及时通知总的进度发生改变
    if (self.progressChangedBlock) { self.progressChangedBlock(); }
}

// 请求完毕（成功|失败
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    ZWDownloadModel *downloadModel = [self getDownloadModel:task.taskIdentifier];
    if (!downloadModel) return;
    
    downloadModel.endDate = [NSDate date];
    
    if ([[ZWFileOperate shared] isCompletion:downloadModel.url]) {
        // 下载完成
        downloadModel.state = ZWDownloadStateComplete;
        if (downloadModel.stateBlock) { downloadModel.stateBlock(ZWDownloadStateComplete, nil); }
    } else if (error){
        // 下载失败
        downloadModel.state = ZWDownloadStateError;
        if (downloadModel.stateBlock) { downloadModel.stateBlock(ZWDownloadStateError, nil); }
    }
    
    downloadModel.downloadSpeed = @"-";
    
    // 关闭流
    [downloadModel.stream close];
    downloadModel.stream = nil;
    
    [self deleteTask:downloadModel];
    
    // 清除任务
    [self.downloadModelDicts removeObjectForKey:@(task.taskIdentifier).stringValue];
    
    // 删除定时器
    if (downloadModel.isNeedSpeed) {
        [DownloadUtil executeOnSafeMian:^{
            
            [downloadModel cancelTimer];
        }];
    }
    
    if (self.stateChangedBlock) { self.stateChangedBlock(); }
}

#pragma mark - 懒加载
- (NSMutableDictionary *)downloadModelDicts {
    if (!_downloadModelDicts) {
        _downloadModelDicts = [NSMutableDictionary dictionary];
    }
    return _downloadModelDicts;
}

- (NSMutableArray<ZWDownloadModel *> *)pausedTasks{
    if (!_pausedTasks) {
        _pausedTasks = [NSMutableArray new];
    }
    return _pausedTasks;
}

- (NSMutableArray<ZWDownloadModel *> *)downLoadingTasks{
    if (!_downLoadingTasks) {
        _downLoadingTasks = [NSMutableArray new];
    }
    return _downLoadingTasks;
}

-(NSMutableArray<ZWDownloadModel *> *)waitingTasks{
    if (!_waitingTasks) {
        _waitingTasks = [NSMutableArray new];
    }
    return _waitingTasks;
}

@end
