// Generates synthetic shop data (fake people, not real) as CSV files in data/
// Run from the repo root: ./data/generate_data
#include<cctype>
#include<cstdio>
#include<fstream>
#include<random>
#include<string>
#include<vector>
#include"names.h"
using namespace std;

#define COUNT(a) (int)(sizeof(a)/sizeof((a)[0]))

const int N_USERS=200000;
const int N_PRODUCTS=5000;
const int N_ORDERS=1000000;

mt19937_64 rng(1);

int rnd(int lo,int hi){
    return uniform_int_distribution<int>(lo,hi)(rng);
}

const char* pick(const char* const* a,int n){
    return a[rnd(0,n-1)];
}

string lower(string s){
    for(char& c:s)c=tolower((unsigned char)c);
    return s;
}

string stamp(int y0,int y1){
    int y=rnd(y0,y1),mo=rnd(1,12),d=rnd(1,28),h=rnd(0,23),mi=rnd(0,59),s=rnd(0,59);
    char b[32];
    snprintf(b,sizeof b,"%04d-%02d-%02d %02d:%02d:%02d",y,mo,d,h,mi,s);
    return b;
}

int main(){
    ofstream users("data/users.csv"),addr("data/addresses.csv"),pay("data/payment_methods.csv");
    ofstream prod("data/products.csv"),orders("data/orders.csv"),items("data/order_items.csv");
    if(!users||!addr||!pay||!prod||!orders||!items){
        fprintf(stderr,"cannot open files in data/ (run from the repo root, mkdir data first)\n");
        return 1;
    }
    char b[256];

    int addrId=0;
    for(int u=1;u<=N_USERS;u++){
        string first=pick(FIRST,COUNT(FIRST));
        string last=pick(LAST,COUNT(LAST));
        string name=first+" "+last;
        int ph1=rnd(100,999),ph2=rnd(0,9999999);
        int by=rnd(1940,2007),bm=rnd(1,12),bd=rnd(1,28);
        int nid=rnd(1000000000,2000000000);
        string created=stamp(2023,2025);
        snprintf(b,sizeof b,"%d,%s,%s%s%d@example.com,+49 %03d %07d,%04d-%02d-%02d,%d,%s",
            u,name.c_str(),lower(first).c_str(),lower(last).c_str(),u,ph1,ph2,by,bm,bd,nid,created.c_str());
        users<<b<<'\n';

        int na=1+(rnd(0,9)<3);
        for(int k=0;k<na;k++){
            addrId++;
            int no=rnd(1,200),zip=rnd(10000,99999);
            string street=pick(STREET,COUNT(STREET));
            string city=pick(CITY,COUNT(CITY));
            string country=pick(COUNTRY,COUNT(COUNTRY));
            snprintf(b,sizeof b,"%d,%d,%d %s,%s,%05d,%s",addrId,u,no,street.c_str(),city.c_str(),zip,country.c_str());
            addr<<b<<'\n';
        }

        unsigned long long h1=rng(),h2=rng();
        int last4=rnd(0,9999),em=rnd(1,12),ey=rnd(27,31);
        snprintf(b,sizeof b,"%d,%d,%s,%04d,%016llx%016llx,%02d/%d",u,u,name.c_str(),last4,h1,h2,em,ey);
        pay<<b<<'\n';
    }

    vector<double> price(N_PRODUCTS+1);
    for(int p=1;p<=N_PRODUCTS;p++){
        price[p]=rnd(100,50000)/100.0;
        string adj=pick(ADJ,COUNT(ADJ));
        string noun=pick(NOUN,COUNT(NOUN));
        string cat=pick(CATS,COUNT(CATS));
        int model=rnd(100,999);
        snprintf(b,sizeof b,"%d,%s %s %d,%s,%.2f",p,adj.c_str(),noun.c_str(),model,cat.c_str(),price[p]);
        prod<<b<<'\n';
    }

    for(int o=1;o<=N_ORDERS;o++){
        int k=rnd(1,4);
        int chosen[4];
        double total=0;
        for(int i=0;i<k;i++){
            int p;
            bool dup;
            do{
                p=rnd(1,N_PRODUCTS);
                dup=false;
                for(int j=0;j<i;j++)if(chosen[j]==p)dup=true;
            }while(dup);
            chosen[i]=p;
            int q=rnd(1,5);
            total+=q*price[p];
            snprintf(b,sizeof b,"%d,%d,%d,%.2f",o,p,q,price[p]);
            items<<b<<'\n';
        }
        int uid=rnd(1,N_USERS);
        string when=stamp(2024,2025);
        string status=pick(STATUS,COUNT(STATUS));
        snprintf(b,sizeof b,"%d,%d,%s,%s,%.2f",o,uid,when.c_str(),status.c_str(),total);
        orders<<b<<'\n';
    }

    printf("generated %d users, %d orders\n",N_USERS,N_ORDERS);
    return 0;
}
