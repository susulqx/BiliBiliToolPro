﻿using System;
using Microsoft.Extensions.Logging;
using Ray.BiliBiliTool.Agent.BiliBiliAgent.Dtos;
using Ray.BiliBiliTool.Agent.BiliBiliAgent.Interfaces;
using Ray.BiliBiliTool.Config;
using Ray.BiliBiliTool.DomainService.Interfaces;

namespace Ray.BiliBiliTool.DomainService
{
    /// <summary>
    /// 账户
    /// </summary>
    public class AccountDomainService : IAccountDomainService
    {
        private readonly ILogger<AccountDomainService> _logger;
        private readonly IDailyTaskApi _dailyTaskApi;

        public AccountDomainService(ILogger<AccountDomainService> logger,
            IDailyTaskApi dailyTaskApi)
        {
            this._logger = logger;
            this._dailyTaskApi = dailyTaskApi;
        }

        /// <summary>
        /// 登录
        /// </summary>
        /// <returns></returns>
        public UseInfo LoginByCookie()
        {
            BiliApiResponse<UseInfo> apiResponse = this._dailyTaskApi.LoginByCookie().Result;

            if (apiResponse.Code != 0 || !apiResponse.Data.IsLogin)
            {
                this._logger.LogWarning("登录异常，Cookies可能失效了,请仔细检查Github Secrets中DEDEUSERID、SESSDATA、BILI_JCT三项的值是否正确");
                return null;
            }

            UseInfo useInfo = apiResponse.Data;

            //用户名模糊处理
            this._logger.LogInformation("登录成功，用户名: {0}", useInfo.GetFuzzyUname());
            this._logger.LogInformation("硬币余额: {0}", useInfo.Money ?? 0);

            if (useInfo.Level_info.Current_level < 6)
            {
                this._logger.LogInformation("距离升级到Lv{0}还有: {1}天",
                    useInfo.Level_info.Current_level + 1,
                    (useInfo.Level_info.GetNext_expLong() - useInfo.Level_info.Current_exp) / Constants.EveryDayExp);
            }
            else
            {
                this._logger.LogInformation("当前等级Lv6，经验值为：{0}", useInfo.Level_info.Current_exp);
            }

            return useInfo;
        }

        /// <summary>
        /// 获取每日任务完成情况
        /// </summary>
        /// <returns></returns>
        public DailyTaskInfo GetDailyTaskStatus()
        {
            DailyTaskInfo result = new DailyTaskInfo();
            BiliApiResponse<DailyTaskInfo> apiResponse = this._dailyTaskApi.GetDailyTaskRewardInfo().Result;
            if (apiResponse.Code == 0)
            {
                //_logger.LogInformation("请求本日任务完成状态成功");
                result = apiResponse.Data;
            }
            else
            {
                this._logger.LogWarning("获取今日任务完成状态失败：{result}", apiResponse.ToJson());
                result = this._dailyTaskApi.GetDailyTaskRewardInfo().Result.Data;
                //todo:偶发性请求失败，再请求一次，这么写很丑陋，待用polly再框架层面实现
            }

            return result;
        }
    }
}
