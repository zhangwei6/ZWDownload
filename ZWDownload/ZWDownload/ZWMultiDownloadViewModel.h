//
//  ZWMultiDownloadViewModel.h
//  ZWDownloadDemo
//
//  Created by Admin on 2020/5/18.
//  Copyright © 2020 ZW. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ZWDownloadCellModel.h"
#import "ZWMultiDownloadModel.h"
#import "ZWDownloadDefine.h"

NS_ASSUME_NONNULL_BEGIN

@protocol ArtDownloadViewModelProtocol <NSObject>

// 刷新指定索引，当 indexPath == nil 时，直接reloadData
- (void)reloadWithIndexPath: (NSIndexPath * _Nullable)indexPath;

// 总任务大小发生改变
- (void)totalDownloadLengthChanged:(ZWMultiDownloadModel *) multiDownloadModel;

// 总任务个数发生改变
- (void)downloadCountChanged:(ZWMultiDownloadModel *) multiDownloadModel;

@end

@interface ZWMultiDownloadViewModel : NSObject

@property(nonatomic, weak) id<ArtDownloadViewModelProtocol> downloadViewModelDelegate;

/**
 *为了设置单个与多个资源下载按钮不同时用参数，因为下载模式不一样
 *单个资源逐个下载并不支持总的进度相关信息
 *如果想一个个添加任务并且也有总的进度等信息，可以使用多个资源下载，并且设置下载资源个数为1就行
 */
@property(nonatomic, assign) NSInteger flag;

// 下载模型(多资源下载模式下使用)
@property(nonatomic, strong) ZWMultiDownloadModel *multiDownloadModel;

// 下载模型(单资源下载模式下使用)
@property(nonatomic, strong) NSMutableArray<ZWDownloadModel *> *downloadModels;

+ (instancetype)init: (id<ArtDownloadViewModelProtocol>)delegate;

// 初始化数据源
- (void)getMultiDownloadModel;

// 添加下载任务(单个)
- (void)addNewTask;

// 添加下载任务（多个）
- (void)addNewTasks;

// 删除选择的下载任务
- (void)deleteChooseTask;

// 清空缓存
- (void)clearCache;

// 全部开始
- (void)resumeAllTask;

// 全部暂停
- (void)pauseAllTask;

// 全部删除
- (void)deleteAllTask;

// 全部取消
- (void)cancelAllTask;

@end

NS_ASSUME_NONNULL_END
