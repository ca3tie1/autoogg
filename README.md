AUTOSETOGG
Author:Castiel
1.此脚本用于配置Godengate + Oracle + DDL 单双向同步。
2.此脚本可配置源与目标，先在源端执行，脚本将自动完成各项进程创建。
3.脚本会检测Oracle和Goldengate环境，请确保以上环境都已正确安装。
4.脚本会自动配置Oracle和Goldengate环境，非首次运行多个步骤可跳过。
5.脚本在Oracle 10g、Oracle 11g与Goldengate 12c环境下测试。
6.**配置双向同步时表清单输入需保持一致，并使用SOURCE-TARGET的格式。**
7.**配置完成若从目标端无法同步到源端且进程正常情况下请在源端执行
    SEND REPLICAT REPLICAT HANDLECOLLISIONS 待正常同步之后再执行
    SEND REPLICAT REPLICAT NOHANDLECOLLISIONS
8.配置使用默认端口7809，动态端口7910-7890，请确保防火墙开启以上端口。
  
10.安装配置顺序建议:(在此之前请先确定oracle与goldengate已安装完成)
  1.源端执行此脚本配置基础环境与EXTRACT 、DATAPUMP、REPLICAT 进程。
  2.手动运行GGSCI并启动EXTRACT和DATAPUMP 并观察进程是否有异常终止。
  3.确定以上进程正常运行后将源端数据库以FLASHBACK_SCN方式备份(建议使用exp)。   
  4.在目标端使用imp将源端备份的文件还原，完成数据库的初始化装载。
  5.在目标端运行此脚本配置对应的REPLICAT进程，使用AFTERCSN FLASHCSN方式启动。  
  6.测试从SOURCE到TARGET同步是否正常。
  7.若开启双向同步再启动目标端EXTRACT和DATAPUMP进程，观察进程是否有异常终止。  
  8.启动目标端的REPLICAT进程，测试从TARGET到SOURCE同步是否正常。
  9.在初始化装载过程中，备份源数据库之前请确保所有事务均已提交。

